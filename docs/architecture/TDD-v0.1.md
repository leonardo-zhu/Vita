# Vita 技术设计文档（TDD v0.1）

**状态：草案**  
**对应产品：** [Vita PRD v0.6](../product/Vita-PRD-v0.6.md)  
**目标：** 为 MVP 建立可实现、可测试且不把未来扩展锁死的技术基线。

本文件把 PRD 中已明确的产品规则翻译为技术约束。模型供应商、公共营养数据来源与最低系统版本均已在 [ADR](ADR.md) 中定稿。

## 1. 架构概览

```text
SwiftUI
 ├─ Chat：自然语言、澄清、Pending 卡片
 ├─ Data：按日期的 Records / 营养汇总 / Goals
 └─ Onboarding：权限与目标初设
        │
Application Services
 ├─ ChatOrchestrator（工具循环）/ AgentToolRunner / ChatHistoryService
 ├─ RecordService / FoodService / GoalService / DayDataService / HealthService
 ├─ LabelScanService（attachNutritionLabel：本地存图，照片随消息发给模型）
 ├─ PendingService（确认门与过期处理）
 ├─ NutritionCalculator
 └─ HealthSyncService（outbox）
        │
Domain + Repositories
 ├─ SwiftData：个人业务数据、Pending、审计、同步映射
 ├─ Bundle JSON：公共营养参考库（只读）
 ├─ Keychain：Conduit 访问令牌（客户端不持有上游模型 Key）
 └─ App Support：营养标签原图
        │
Platform adapters
 ├─ HealthKitAdapter
 ├─ LLMClient（可替换 Provider）
 └─ LabelImageEncoder（标签照片按配置缩放后发给模型）
```

### 1.1 分层原则

- `Presentation` 不直接操作 SwiftData 或 HealthKit，只调用 Application Service。
- `Domain` 只包含值类型、规则和协议；不依赖 SwiftUI、HealthKit 或模型 SDK。
- `Data` 实现 Repository、SwiftData schema、静态参考库读取与本地文件存储。
- `Platform` 封装 HealthKit、Keychain、网络模型和图片编码。每项均应可替换为测试 double。
- Agent 不是业务层的特权主体；它和手工 UI 都使用同一组 Application Service。

### 1.2 推荐模块布局

仓库顶层按子系统分目录；iOS 工程全部位于 `ios/`：

```text
ios/
  project.yml            XcodeGen 配置
  Vita/
    App/                 app 入口、依赖装配、导航
    Features/            Chat、Data、Nutrition、Goals、Onboarding
    Domain/              实体、值对象、Repository 协议、计算规则
    Application/         各类 Service 与 use case
    Data/                SwiftData models、repository、JSON decoder
    Platform/            HealthKit、LLM、Keychain、文件存储与图片编码
  Resources/ReferenceFood/  已授权的只读数据集
  VitaTests/
  VitaUITests/
admin/                   Vita Admin（Next.js）：配置发布与诊断日志，见 vita-admin.md
shared/config-schema/    远程配置的 JSON Schema 与测试用例，iOS 与 Admin 共用
docs/
```

模型网关 Conduit 是独立仓库，见 [Conduit 项目设计](llm-gateway-project.md)。

## 2. 技术选型与运行边界

| 领域 | 选择 | 原因 |
| --- | --- | --- |
| UI | SwiftUI（最低 iOS 17） | iPhone 原生体验、状态驱动的 Chat / Data 双视图。 |
| 并发 | Swift Concurrency（`async/await`、actors） | HealthKit、模型网络与持久化操作可取消且不会阻塞 UI。 |
| 业务存储 | SwiftData | 单人小数据量、离线优先；通过 Repository 隔离。 |
| 健康平台 | HealthKit | PRD 指定的唯一直接外部健康入口。 |
| 模型接入 | 经 Conduit 网关的 Responses API + provider-neutral `LLMClient` | 客户端用 `URLSession` 对接 Conduit 的 `/v1/responses`；上游 Provider 由 Conduit 管理；领域逻辑不绑定具体模型或 SDK。 |
| 远程配置 | `ConfigProvider` + 静态 JSON（现阶段不签名） | prompt、模型别名、超时等可远程调整，强制规则留在代码里；见 [Vita Admin 设计](vita-admin.md)。 |
| 图片解析 | 多模态模型直接读图 | 照片随用户消息发给模型，模型读出数值后经 `proposeFoodChange` 走确认卡；原图同时存本机作为来源依据（ADR-016）。 |

MVP 不需要用户账号、业务数据后端、实时协作或云端数据库。业务数据不进入任何服务端。客户端有三个网络出口：

1. **模型请求：** 全部发往独立网关 Conduit（目前上游为火山方舟）。发送的内容是用户主动发给 Agent 的文本，加上为完成该请求所需的本地数据：当天记录摘要，以及**个人食品库的结构化整库摘要**（名称、品牌、包装、ID、每基准营养；PRD §3.1 要求由模型做语义匹配，体量为几十条，可由配置 `includePersonalFoodSummary` 关闭）。健康数据只在模型调用相应工具时按需提供；营养标签照片按配置缩放后随消息发给模型（ADR-016）。集成细节见 [模型 Provider 集成规范](../contracts/llm-provider.md)。
2. **远程配置拉取：** 只读下发，请求不携带用户标识，见 [Vita Admin 设计](vita-admin.md)。
3. **诊断日志上报：** 可在设置页关闭，只含元数据，不含对话、饮食、健康数据和图片。

Vita Admin 与 Conduit 是配套服务，不存储业务数据。当前阶段不上传用户内容；将来如需备份或数据收集，须新 ADR 与用户显式同意。

## 3. 领域模型

### 3.1 日期 Session 与时间表达

`DaySession` 是日期上下文，不是传统聊天标题。其主键为 `localDate`（ISO `YYYY-MM-DD`）+ 本地日历标识；默认进入今天，历史日期可继续写入。

```text
DaySession
  id, localDate, timeZoneIdentifier, revision, createdAt, updatedAt
  1 ── * ConsumptionRecord
  1 ── 0..1 PendingAction
```

`EventTime` 不能把“中午”伪装成 12:00。使用下列值对象：

| 字段 | 含义 |
| --- | --- |
| `localDate` | 记录所属日期，必须等于 Session 日期。 |
| `precision` | `exact` / `approximate` / `mealPeriod` / `dateOnly` / `defaultedEntryTime`。 |
| `timestamp` | exact / approximate / defaultedEntryTime 存储的本地时刻。 |
| `mealPeriod` | 仅 mealPeriod：breakfast / lunch / dinner / snack / other。 |
| `timeZoneIdentifier` | 表达发生时的 IANA 时区，避免旅行或时区变化重解释旧数据。 |

`createdAt` 始终为 UTC；`eventTime` 始终表示摄入发生的用户本地语义。创建 Session 时固定其日期和时区，后续切换时区不重写历史 Session。

若用户完全没有表达时间，默认采用录入时刻：当前日期 Session 使用当前本地日期时间；历史日期 Session 使用“该 Session 日期 + 当前本地时分秒”，以保证 Record 不跨出所在 Session。此值的 `precision` 必须是 `defaultedEntryTime`，让 UI 可以说明“按记录时间”。用户一旦明确说“午餐”“晚上”“今天中午”等模糊时间，不适用该默认值，仍保存其原始时间精度。

### 3.2 正式实体

```text
ConsumptionRecord
  id, sessionId, eventTime, mealLabel?, note?, revision,
  createdAt, updatedAt
  1 ── * ConsumptionItem

ConsumptionItem
  id, recordId, groupName?, displayName,
  originalAmountText, normalizedQuantity?, normalizedUnit?, amountSource,
  nutritionSource, nutritionSnapshot, includeInSummary,
  foodProductId?, foodVersionId?, referenceFoodId?,
  createdAt, updatedAt

FoodProduct
  id, name, brandOrSupplier?, packageQuantity?, packageUnit?, note?,
  activeVersionId?, createdAt, updatedAt
  1 ── * FoodVersion

FoodVersion
  id, foodProductId, nutritionPerBaseUnit, baseUnit, labelImageReference?,
  sourceKind, sourceNote?, createdAt, retiredAt?

DailyGoal
  id, effectiveFrom, proteinG?, energyKcal?, fatG?, carbohydrateG?,
  origin, evidenceSnapshot, revision, createdAt, updatedAt
```

目标更新不覆盖旧行：每次更新新增一条 `DailyGoal`（新的 `effectiveFrom` 与递增 `revision`），旧行保留，因此“改回去”只是再写一条新行，旧值可随时读出。

所有金额/营养值均使用 `Decimal`，绝不使用二进制浮点数作为持久化计算源。UI 可显示按规则四舍五入的值，但储存值保留计算精度。`nutritionSnapshot` 是 Item 创建/修改当时的蛋白质、脂肪、碳水、能量及计算基准，确保 Food Version 或公共数据集修订不会改变历史记录。

快照同时记录**这组数是怎么得来的**，以便任何历史 Item 都能解释：

| 字段 | 含义 |
| --- | --- |
| `nutritionSource` | `personalFoodVersion` / `referenceFood` / `aiEstimated`，决定卡片与详情页如何标注。 |
| `sourceRef` | 对应的 Food Version ID 或参考条目 ID（aiEstimated 无）。 |
| `basis` | 计算基准：每基准量的营养值与基准量（如 per 100g）。 |
| `quantityUsed` | 参与计算的标准化用量。 |
| `computedBy` | `client`（personal / reference：客户端按 `basis × quantityUsed` 计算）或 `model`（aiEstimated：采用模型提交的数值）。 |
| `estimateBasis` | 仅 aiEstimated：模型给出的一句话估算依据。 |

personal / reference 的数值一律由客户端重算，模型即使带了数值也以客户端结果为准；aiEstimated 因无数据依据才采用模型数值，且必须带 `estimateBasis`。

### 3.3 枚举与来源

| 名称 | 值 |
| --- | --- |
| `AmountSource` | `userMeasured`, `userStated`, `packageConversion`, `aiEstimated` |
| `NutritionSource` | `personalFoodVersion`, `referenceFood`, `aiEstimated` |
| `FoodVersionSource` | `nutritionLabel`, `manualEntry`, `referenceDerived` |
| `GoalOrigin` | `initialRecommendation`, `explicitUserCommand`, `manualOnboarding` |
| `SyncState` | `synced`, `pending`, `failedRetryable`, `requiresUserResolution` |

`normalizedQuantity` 可为空：例如用户明确要求记录但无法可靠换算的描述；这种项目必须作为 AI estimate 并在卡片中明确展示，不能伪称用户实测。营养无法合理估算时可以保留为“不计入汇总”的 Item。

### 3.4 临时与辅助实体

| 实体 | 作用 | 保留规则 |
| --- | --- | --- |
| `PendingAction` | 正式写入前的可恢复草稿、目标快照、创建日期、TTL、状态和 payload hash | 30 分钟或跨日即清除；从不计入汇总。 |
| `HealthSyncMapping` | `recordId + nutrientType + HKSampleUUID` 与状态 | 删除成功后删除；权限撤销时保留待解决映射。 |
| `HealthSyncOperation` | outbox 中的 create / replace / delete 操作、序号、重试信息 | 成功后保留最小审计结果，失败可重试。 |
| `AuditEvent` | 操作类型、对象 ID、时间、结果、错误码、request ID | 本地技术诊断；不保存完整自由文本或原始图片。 |
| `ChatMessage` | `id, sessionId, role(user/assistant/toolSummary), text, cardRef?, createdAt`；`cardRef` 为 `pending:<id>`（回复附带的确认卡）、`record:<id>` 或 `label:<scanId>`（用户消息附带的营养标签照片） | 属于 DaySession，随 Session 保留，供折叠回看与继续对话；不保存 API Key、图片原文或完整工具 payload。 |

发送给模型的上下文由 `ChatOrchestrator` 组装，每轮读取一次生效配置，一轮中途不切换：

- **系统指令**：配置中的系统 prompt，后接个人食品库整库摘要。这部分很少变化，和工具定义一起构成稳定的前缀，命中服务商的隐式缓存（命中数见诊断日志 `tokensCached`）。
- **客户端状态**：会话日期与星期、当前本地时间与时区、当天 revision、活跃 Pending ID、当天各记录与 Item 的 ID 和原始用量。每轮都变，作为一条 `system` 消息放在本轮用户消息前，不进系统指令，以免打断前面的缓存前缀。
- **历史**：当前 `sessionDate` 最近 `context.maxRecentMessages` 条用户与助手文字。工具调用不重放；附带确认卡的助手消息追加一句“［客户端注］”说明卡片结局（已确认 / 已取消 / 已过期 / 待确认），避免模型只模仿“已生成确认卡”的说法而不调用工具；带 `label:` 引用的用户消息重放时照片与 `labelScanId` 一起重放（历史在缓存前缀里，多半按缓存价计费）。
- **工具循环**：最多 8 轮；超出则停止并提示用户换个说法。
- **保存**：一轮成功后才同时保存用户消息与回复；失败或用户停止时都不保存，界面把原文与照片放回输入框。本轮已生成的 Pending 保留（它不是正式数据）。

不依赖远端 `previous_response_id`（见 [Provider 规范](../contracts/llm-provider.md) §5）。生成中界面展示模型的推理摘要与已调用工具的步骤清单；推理内容只展示，不保存、不回传。

Pending 需要落盘以便 App 重启恢复，这是 PRD 所说的“临时持久化”；它不是 Consumption Record、Food Version 或正式历史的一部分。

## 4. 数据完整性与计算

### 4.1 事务边界

确认 Pending 时，在一个 SwiftData 事务内完成：校验 revision → 写入/更新正式实体 → 递增 Session revision → 建立 HealthSyncOperation → 写 AuditEvent。事务失败时没有部分 Record 或部分 Item。

HealthKit 不支持加入本地数据库事务，因此它通过 outbox 在本地提交后异步执行。UI 显示“已记录”与“HealthKit 同步中/需处理”是两个不同状态。

### 4.2 NutritionCalculator

1. 根据标准化数量与食品的 `per 100g`、`per 100ml` 或包装基准计算 Item 营养；
2. 对 `includeInSummary = true` 的 Item 相加得到 Record 与 DaySession 汇总；
3. 以 `Decimal` 计算，展示时能量取整数 kcal、宏量营养素取一位小数；
4. `aiEstimated` 同样进入计算，但 UI 必须展示来源，不能与可靠标签值混淆；
5. 小量调味料是否纳入由提案明确决定，且该决定随 Item 快照保存。

不保存“可被重新推导的日总量”作为唯一真相。可使用缓存提升界面性能，但缓存必须由 Record/Item revision 失效并可完全重建。

### 4.3 Food Version 不可变性

Food Version 创建后不可编辑；纠正标签、配方或包装时新建 Version 并更新 `FoodProduct.activeVersionId`。历史 Item 同时保存 Version ID 和营养快照，故即使后续删除食品显示入口，历史记录仍可解释和计算。

## 5. Agent 与确认安全模型

### 5.1 请求生命周期

```text
用户输入
  → ChatOrchestrator 组装当前日期与最小上下文
  → LLMClient / 工具循环（只读、澄清或 propose）
  → PendingService 校验并保存临时提案
  → 用户点击确认
  → Record/Food Service 本地事务提交
  → HealthSyncService outbox 同步
  → Data 刷新 + 审计
```

模型可生成提案但没有 `confirmPending` 的调用权。用户点击卡片确认时，客户端必须使用当前 Pending 的原始、已校验 payload；不能采用模型随后在自然语言中重新描述的字段。

工具详情与 JSON 约束见 [Agent 工具契约](../contracts/agent-tools.md)。

### 5.2 Session 隔离

- 当前 `sessionDate` 由导航状态提供并注入所有工具调用。
- 模型提到其他日期时，客户端返回“需要切换日期”的结构化结果；不自动导航、不跨 Session 写入。
- 每个 Session 维护单调递增 `revision`。创建 Pending 时捕获 revision；确认时若不匹配，作废并提示重新确认。
- 同日期活跃 Pending 阻止新独立写入，但允许以同一 Pending 做修正、澄清或取消。

### 5.3 过期策略

默认 TTL 是创建后 30 分钟，并受本地日历的次日 00:00 截止约束：`min(createdAt + 30m, nextLocalMidnight)`，其中 `nextLocalMidnight` 是 `createdAt` 所在本地自然日的次日 00:00，与 `sessionDate` 无关（历史日期 Session 同样适用，否则创建即过期）。应用启动、回到前台、切换 Session、显示卡片和提交前均调用 `expireDuePendingActions()`。

## 6. HealthKit 集成与同步

### 6.1 权限和读取

Onboarding 请求且仅请求 PRD 所列类型：身高、体重、体脂率、出生日期、生理性别、睡眠、活动能量的读取，以及膳食能量、蛋白质、脂肪、碳水的写入。HealthKit 的读取授权状态不能简单等价于“数据一定存在”，所以 UI 必须区分未授权、已授权但无数据、查询失败和有数据。

Vita 不把读取的 HealthKit 数据复制成长期业务主数据；仅保留目标生成所需的最小 evidence snapshot（数值来源、读取时间、是否估算），以解释目标为何如此生成。

### 6.2 目标初设算法

这是可配置的默认建议，不是医疗建议：

1. 体重缺失时阻止自动生成，要求手动输入或跳过；
2. 用 Mifflin–St Jeor 计算 BMR（需要身高、体重、年龄和生理性别）；
3. 若有当日 Active Energy，估计 TDEE = BMR + Active Energy；否则 TDEE = BMR × 1.375，并标记为估算；
4. 默认蛋白目标 = `1.8 g × 体重(kg)`；默认能量目标 = `90% × TDEE`；
5. 展示输入、公式、估算标签和结果，用户一次确认后创建 Goal；明确指令的后续更新直接执行。

体脂率可作为展示和未来分析输入，不用于 MVP 的默认公式。所有数值与系数集中在 `GoalRecommendationPolicy`，不要散落在 prompt 中。最终可在首次真实使用后调整默认值。

### 6.3 写入与撤销

每条已确认的 Record 依营养字段写入独立的 `HKQuantitySample`，在 metadata 中写入 Vita Record ID、Item/Record revision、时间精度和写入 schema 版本。保存 Sample UUID 到 `HealthSyncMapping`。

```text
创建 Record：本地提交 → create Samples → 保存 UUID mapping
修改 Record：本地提交 → delete 旧 UUID Samples → create 新 Samples → 更新 mapping
删除 Record：本地提交 → delete 旧 UUID Samples → 删除 mapping
```

操作必须串行化到同一个 Record：后一个修改不能越过前一个删除/写入操作。删除失败不得直接清 mapping；应标记 `requiresUserResolution` 并提示当前没有权限或需要稍后重试，以避免静默孤儿 Sample。

### 6.4 非精确 event time

HealthKit Sample 必须有具体时间，而 Vita 的业务时间可以只有日期或餐段。为兼顾两者，采用以下策略：

| Vita precision | 写入 HealthKit 的时间 | metadata |
| --- | --- | --- |
| exact / approximate / defaultedEntryTime | 使用保存的 timestamp | 原始 precision；defaultedEntryTime 额外标记 `vita.timeDefaultedAtEntry = true` |
| mealPeriod | 使用该餐段的代表性时间：08:00 / 12:30 / 18:30 / 15:30 | `vita.timeWasRepresentative = true`、原始 mealPeriod |
| dateOnly | 使用当日 12:00 | `vita.timeWasRepresentative = true` |

Vita UI 继续展示原始时间精度，不将代表性时间倒灌为业务事实。`defaultedEntryTime` 则明确展示为“按记录时间”，避免被误认为是用户主动提供的精确时刻。

## 7. 公共营养参考库

参考库是随 App 内置的静态只读资源，不使用网络查询，也不设计运行时版本或用户编辑。条目格式**以 [公共营养参考库规范](../reference-food-library.md) §3 为唯一准绳**（稳定 ID `vita.reference.*`、`canonicalName`、`aliases`、`preparationState`、每 100g 的 `nutrients`、`densityGPerMl`、`source`），本文不再重复 schema，避免两处漂移。

查询只做 canonical name 与别名规范化后的精确匹配：统一空白、全半角、常见单位尾缀与已维护别名。结果超过一条即返回候选并要求澄清，不做 embedding、向量检索或隐式模糊选择。

公共库采用来源感知的优先级：对中国日常食材，已获有效使用/分发授权的《中国食物成分表》或中国食物成分数据中心数据优先；USDA FoodData Central 用于中国库未覆盖的通用/国际食材，并在其中以 Foundation Foods 优先、SR Legacy 补充。USDA 数据为 CC0/public domain。中国数据仅限用户本人的私有本地构建：不提交进 Git、不公开分发、不用于 TestFlight/App Store；若范围改变须重新核验授权。Branded Foods、FNDDS 与复合菜不进入公共库。详细的选择、转换、署名与校验规范见 [公共营养参考库规范](../reference-food-library.md)；资源目录说明位于 `ios/Resources/ReferenceFood/README.md`。

## 8. 隐私、安全与可靠性

- 业务库、标签原图和审计日志存于 app sandbox；Conduit 令牌只存 Keychain（设置页只显示末四位），不写入 SwiftData、日志、测试 fixture 或截图。客户端不持有上游模型 Key。
- 远程配置只能改变 prompt、模型别名与运行参数，不能改变确认门、工具 schema、Conduit 地址或写入规则；配置只从构建配置里的唯一 HTTPS 地址拉取，校验失败回退到缓存或内置默认值。
- 诊断日志上报默认只含元数据（错误码、配置版本、耗时、token 数、轮换的匿名安装 ID），可关闭；不含任何用户内容。事件格式见 `shared/diagnostics/batch.schema.json`，服务端拒收多余字段。
- 模型请求的上下文见 §3.4：当前 Session 摘要、个人食品库整库摘要（可配置关闭）和用户当前消息。健康原始数据只在模型调用 `getHealthSnapshot` / `getGoalRecommendation` 时传递，并标注来源。
- 工具诊断日志用 `os.Logger`（subsystem `com.leonardo.vita`，category `agent.tools`）只记工具名与结果码，不记参数或结果内容。
- 网络错误、模型输出无效、工具参数不合格、HealthKit 权限撤销均是可显示且可恢复的状态，不能转化成静默写入。
- 营养标签：用户在输入框“+”拍照或从相册选图，图片压缩到长边 2000 px 存于 App Support，作为 Food Version 的来源依据；发送时按远程配置 `labelImage`（长边、JPEG 质量、`detail`）再缩放，以 `input_image` 随消息发给模型，不额外弹同意说明（ADR-016）。本地路径不外发，模型只拿到 `labelScanId`。
- 审计日志记录结构化操作与错误码，不默认保存完整对话。可在设置页提供“清除本地诊断日志”的维护入口，但不属于 MVP 核心界面。

## 9. 非目标与扩展点

数据备份：业务库位于 App sandbox，依赖系统的 iCloud / 设备备份；MVP 不提供应用内导出或自建云备份。已确认的营养数据另有一份在 Apple Health 中。Apple Watch 端展示是未来可选方向，MVP 不做，也未做技术设计。

本设计不包含多用户、账号、云同步、App Store 合规、Google Health 直接适配、复杂公共库检索、库存、用户可见历史回滚或 Apple Watch。

未来扩展以新增 `ToolDefinition`、`Application Service` 与 `Platform Adapter` 为主，不能让新 Agent 能力绕过确认门或直接写入持久层。若引入服务端，仍应把“模型提案”和“设备端确认/提交”维持为两个独立阶段。

## 10. 验收条件

- 任何复杂数据写入在确认前都不会出现在 Records、Goals（明确指令除外）或 Apple Health。
- 每个历史 Item 均可说明其 Amount Source、Nutrition Source、来源引用和营养快照。
- 同一日期活跃 Pending 的数量永远不大于 1，且过期/跨日不会残留。
- 修改/删除同步过的 Record 后，旧 HealthKit Sample 不会与新值叠加；无法删除时能被用户感知且 mapping 不丢失。
- 切到历史日期后写入仅影响该日期；模型提到另一日期只请求切换。
- HealthKit 或模型不可用时，Data 与已经保存的本地记录仍可使用。
