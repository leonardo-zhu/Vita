# Vita Agent 工具契约

**状态：已实现（2026-10-31）；2.0 起整体移到服务端（2026-11-04）。** 1.0 的实现在 iOS（`AgentToolCatalog`、`AgentToolRunner`、`ProposalToolHandler`、`ChatOrchestrator`，已删除）。现在的实现在 Vita API 的 `api/src/agent/`：`tools.ts`（只读工具与 `updateGoal`）、`proposals.ts`（Propose 类）、`orchestrator.ts`（工具循环）、`config.ts`（工具清单与描述）。

> **2026-11-05 之后的规则（API 与 prompt v7–v10）：** ① `updateProduct` 也可改 `product.package`（如“一袋是 288 g”）；② 按营养标签新建产品（`createProduct` + `version.source = nutritionLabel`）必须带 `product.package`，否则返回 `packageRequired`，模型应先问净含量再提案；③ 提案工具返回 ok 后这一轮立即结束，不再请求模型说“请确认”，要说明的在调用前说完；④ 确认后的接续第一轮请求带 `tool_choice: required`，仍没调工具时服务端提醒一次；⑤ `packageUnavailable`（旧食品没有包装规格却按“一袋”记）的错误信息会指引模型按克数记、确认后用 `updateProduct` 补包装。依据与实验见《Agent 调优记录》。

> **食品库与营养素（2.3，M5）：** `proposeFoodChange` 新增意图 `updateProduct`（`productId` 加 `product.name` / `product.brandOrSupplier` / `product.aliases` 中要改的项，`aliases` 是改后的完整列表；营养值不变，不需要 `version`）；`createProduct` 的 `product.aliases` 记用户的常用叫法。营养值（`version.values` 与 AI 估算的 `nutrition.values`）可带可选的 `sodiumMg`、`saturatedFatG`、`sugarG`，只在来源上有时填；AI 估算的这三项会被丢弃。

> **批量录入（2.1）：** 一条用户消息可以带多张营养标签照片（最多 6 张），附件说明里按顺序列出各张的 `labelScanId`。一天只能有一张确认卡，模型每次只对一张照片提 `proposeFoodChange`，用 `afterConfirm` 写明接下来处理哪几张，确认后经 `/continue` 接着处理。
>
> **2.0 阅读说明：** 下文的“客户端”指执行工具、管 Pending 与写入的一方，2.0 起就是 Vita API；工具、参数、状态机与确认门都没变。手机只负责展示确认卡、调确认 / 取消接口，以及按变更流写 Apple 健康（《Vita 2.0 架构设计》§9）。“客户端状态”消息里的界面状态（当前日期等）由手机随请求带上，服务端组装。

## 目标

将“理解自然语言”与“改变本地数据”严格分开。模型负责结构化理解、查询与建议；客户端负责校验、Pending 生命周期、事务写入和 HealthKit 同步。

客户端从当前界面状态注入 `sessionDate`，而不是信任模型自行推断的日期。实现中的分工：

- `requestId` 一律由客户端生成（同一轮的所有工具调用共用，与 `X-Request-Id` 对应），模型给的值被覆盖。
- 模型可以省略 `sessionDate` 与 `expectedRevision`，客户端用当前值补上；模型给了别的日期则保留，由处理器返回 `requiresDateSwitch`。
- 当前日期、revision、活跃 Pending 与当天记录 ID 已在系统上下文中提供，模型通常不必先调用 `getDaySummary`。

## 权限级别

| 级别 | 工具 | 行为 |
| --- | --- | --- |
| Read | `getDaySummary`、`getRecordDetail`、`searchPersonalFoods`、`searchReferenceFoods`、`getGoals`、`getHealthSnapshot`、`getBodyComposition`、`getGoalRecommendation` | 仅读取或由客户端计算预览；历史日期可读。`getGoalRecommendation` 不写入任何数据。 |
| Propose | `proposeRecordChange`、`proposeFoodChange`、`proposeRecordDeletion` | 校验输入后创建或替换该日期唯一的 Pending；不写正式业务数据。 |
| Direct command | `updateGoal` | 仅在用户指令明确、参数完整时直接执行；否则模型先在对话中取得确认，不创建 Pending。 |
| Client-only commit | `confirmPending`、`cancelPending`、`expirePending`、`runHealthSync`、`commitInitialGoals`、`submitManualBodyMetrics`、`attachNutritionLabel` | 不暴露给模型。由卡片交互、表单、系统选择器、时钟或应用服务调用。 |

## 公共信封

```json
{
  "requestId": "uuid",
  "sessionDate": "2026-09-17",
  "expectedRevision": 12,
  "payload": {}
}
```

- `expectedRevision` 是该 Session 数据快照版本；提交时不匹配则拒绝，并要求重新生成提案。
- 所有 ID 使用客户端生成的 UUID。模型可引用已返回的 ID，但不可构造一个 ID 来越权访问其他日期。
- 查询结果只返回完成任务所需字段；图片、原始提示词和 Keychain 信息永不发送给工具结果。

## 关键工具

### `searchPersonalFoods`

输入：自然语言 `query`。输出：**个人食品库的全部产品**（`productId`、名称、品牌、包装规格、`activeVersionId`、每基准营养），`query` 只是模型想找什么的提示，客户端不据此过滤。

客户端不做字符串或模糊匹配（ADR-016、PRD §3.1）：同一份整库摘要已随系统上下文提供，由模型按语义判断用户说的是哪一个；有多个可能或不确定时先问用户。

### `searchReferenceFoods`

输入：`query` 和可选 `aliases`。输出：精确名称或别名命中的参考条目。若结果不唯一，模型必须发起澄清；不得从多个候选中猜测“生/熟”等实质属性。

### `proposeRecordChange`

输入包含意图（`create` / `appendItems` / `replaceItem` / `removeItem`）、目标 Record ID（非创建时必填）和完整的候选 Record 快照。每个 Item 必须包含：

- 用户原始用量表达、标准化 `g` 或 `ml`、`amountSource`；
- `nutritionSource`（personal / reference / aiEstimate）及其来源引用：
  - personal / reference：模型只提交 Food Version ID 或参考条目 ID 加标准化用量，**不提交营养数值**。客户端按「每基准值 × 用量」自行计算营养快照，并记录计算依据（见 TDD §3.2 `nutritionSnapshot`）。
  - aiEstimate：模型提交营养数值，并必须附 `estimateBasis`（一句话说明估算依据，如假设的单个重量、参照的常见值）；客户端存入快照并标记为估算，卡片上显式展示。
- 是否纳入汇总、可选 Group、可选 Meal Label；
- 事件时间值和精度，而非伪造的精确时间。

客户端再次校验：Session 日期一致、目标记录属于当前 Session、标准化单位有效、营养值非负、引用的 Food Version/参考条目存在。校验成功后覆盖该日期既有 Pending，生成确认卡；失败则返回可面向模型解释的错误。

当用户完全未表达事件时间时，客户端（不是模型）注入“Session 日期 + 当前本地时分秒”，并标记 `defaultedEntryTime`。用户明确表达餐段、模糊时间或仅日期时，不得以当前时间覆盖。

#### 参数格式（Phase 2 定稿）

`proposeRecordChange` 的 `payload`：

```json
{
  "intent": "create",
  "recordId": "uuid（非 create 时必填）",
  "itemId": "uuid（replaceItem / removeItem 必填）",
  "record": {
    "eventTime": { "precision": "mealPeriod", "mealPeriod": "lunch" },
    "mealLabel": "午餐",
    "items": [
      {
        "displayName": "鸡蛋",
        "originalAmountText": "2 个鸡蛋、共 108g",
        "quantity": { "amount": 108, "unit": "g" },
        "amountSource": "userMeasured",
        "nutrition": { "source": "referenceFood", "referenceFoodId": "vita.reference.egg.whole.raw" },
        "includeInSummary": true
      }
    ]
  },
  "items": ["appendItems 用"],
  "regroup": [{ "itemId": "已有 Item 的 uuid（appendItems 可选）", "groupName": "红烧罗非鱼" }],
  "item": "replaceItem 用",
  "replacesPendingId": "修正当前 Pending 时填"
}
```

- `mealLabel`（卡片标题）只能是 `早餐` / `午餐` / `晚餐` / `加餐`，可省略（App 按时间段显示）；其他值（包括 `dinner` 这类英文）返回 `malformedArguments`（2026-11-10 起，之前是自由文本）。
- `groupName`（可选）：几项合起来是一道菜或一杯饮品时（拿铁 = 咖啡 + 牛奶），这几项填同一个菜名，App 把它们归在这个名字下显示；单独吃的食品不填。服务端不校验是否该填（2026-11-11 起参数描述与 prompt v11 写明了这条）。
- `regroup`（可选，仅 `appendItems`，2026-11-11 起）：`[{ itemId, groupName }]`，把同一条记录里已有的项顺带改到某个菜名下（`groupName` 省略表示移出分组），和追加的项在同一张卡里确认。ID 不属于这条记录或重复时返回 `itemNotFound`；分组没变的项略过。确认卡的 `regroupedItems` 列出这些项，不计入合计。
- `eventTime` 省略表示用户没表达时间，由客户端注入 `defaultedEntryTime`；模型不能自己声明该精度。`exact` / `approximate` 用 `time: "HH:mm"`，日期与时区取当前 Session。
- `quantity.unit` 可用 g / kg / mg / 斤 / 两 / ml / L 及中文写法，由客户端标准化为 g / ml；计数单位（个、碗）须由模型换算或省略用量走估算。
- `nutrition.source` 为 `referenceFood` / `personalFoodVersion` 时只看 ID，附带的 `values` 一律忽略；`aiEstimated` 必须带 `values` 与 `estimateBasis`。
- `proposeRecordDeletion` 的 `payload` 为 `{ "recordId", "replacesPendingId"? }`。
- 三个 Propose 工具都可带顶层可选字段 `afterConfirm`（字符串）：这次请求在卡片确认后还有下一步时写下（如先存食品库、再记这一份）。客户端在用户确认后自动接着跑一轮，以客户端消息告诉模型“已确认 + 下一步”，不保存用户消息；用户取消则丢弃。它只记在内存里，App 重启后丢失。
- 结果为 `{ ok, pendingId?, requestedDate?, error?: { code, message } }`。错误码：`requiresDateSwitch`、`pendingActive`、`pendingNotFound`、`revisionConflict`、`recordNotFound`、`itemNotFound`、`emptyRecord`、`invalidItem`、`missingField`、`invalidField`、`malformedArguments`、`unknownTool`。

### `proposeFoodChange`

输入为 Food Product 与不可变 Food Version 草稿，并包含标签图片本地引用（如有）及其解析置信信息。创建 Product 或 Version 都需要 Pending 确认。AI 纯估算项目不得作为输入来源创建 Food Version。

#### 参数格式（Phase 3 定稿）

```json
{
  "intent": "createProduct",
  "productId": "uuid（addVersion 必填）",
  "expectedActiveVersionId": "uuid（addVersion：模型看到的生效版本）",
  "product": { "name": "某品牌纯牛奶", "brandOrSupplier": "某乳业", "package": { "amount": 250, "unit": "ml" }, "note": null },
  "version": {
    "source": "nutritionLabel",
    "labelScanId": "uuid（nutritionLabel 必填，来自 attachNutritionLabel）",
    "referenceFoodId": "referenceDerived 必填",
    "basis": { "amount": 100, "unit": "ml" },
    "values": { "energyKcal": 65, "proteinG": 3.2, "fatG": 3.6, "carbohydrateG": 4.8 },
    "note": "可选"
  },
  "replacesPendingId": "修正当前 Pending 时填"
}
```

- `source` 只接受 `nutritionLabel` / `manualEntry` / `referenceDerived`，其他（包括 `aiEstimated`）返回 `estimateNotAllowed`。
- `referenceDerived` 的基准与营养值由客户端从参考库复制，模型给的忽略。
- `nutritionLabel` 的 `values` 由模型读照片给出（能量只有千焦时由模型 ÷4.184 换算），图片引用由客户端按 `labelScanId` 查得，模型拿不到也不能伪造本地路径。
- 提案后产品的生效版本已变化时，确认会失败并作废（`revisionConflict`）。
- 新增错误码：`estimateNotAllowed`、`productNotFound`、`unknownLabel`、`invalidFood`。

### `updateGoal`

输入：`energyKcal`、`proteinG`、`fatG`、`carbohydrateG` 中的一项或多项（正数，只传要改的项）和必填的 `userCommand`（用户原话，作为指令证据）。新值从当前会话日期起生效。

能量目标有两种模式（TDD §6.2、ADR-018）：给了 `energyKcal` 就是**固定**目标；`goalType`（`maintain` / `lose` / `gain`，调整用该类型默认值）、`energyPercent`（吃到每日消耗的百分比，50–150）、`energyAdjustmentKcal`（每天相对消耗的千卡，缺口为负，−1500 到 +1500）或 `energyAuto: true`（沿用上次的类型与调整）任一出现，就是**随活动计算**。两种不能同时给（`invalidField`）；从没自动设定过目标时恢复随活动计算返回 `noEnergyPlan`，请用户先在 Data 页生成一次。`getGoals` 与本工具的结果都带 `energyMode`（`auto` / `fixed`）、`energyPlan` 与当天的 `energyToday`（平时活动、活动预估、计入的活动、消耗、调整）。客户端仅接受完整明确指令；建议性语言应由模型在聊天中澄清后再调用。成功后递增 Goal revision 并记录审计日志。

结果必须返回**旧值与新值**，模型据此复述。没有专门的撤销机制：用户想反悔时，以明确指令（如“改回 160g”）再次调用 `updateGoal` 即可；旧值可由 `getGoals` 的 revision 历史取得。

### `getGoalRecommendation`

只读。客户端用 `GoalRecommendationPolicy`（TDD §6.2）基于 HealthKit 读数（含近 7 天日均活动）与手动补录数据计算，默认目标类型为减脂（85%），返回输入项（含来源：HealthKit / 手动 / 估算）、公式、结果与缺失项。体重缺失时返回“无法生成”。**模型不自行计算目标数值。**

首次生成目标属于“一次性确认”，不走 Pending：模型展示预览，用户在目标预览卡上点击确认后由客户端调用 `commitInitialGoals` 写入（`origin = initialRecommendation`）。

### 只读工具的输出

- `getDaySummary`：`date`（可省略，默认会话日期；历史日期可读，`writable` 标明能否写）、`revision`、每条记录（ID、事件时间、餐次、各 Item 的 ID / 原始用量 / 标准化用量 / 两种来源 / 营养）、当天合计、生效目标、活跃 Pending。
- `getRecordDetail`：`recordId`，只能读当前会话日期的记录。
- `searchReferenceFoods`：`query` 与可选 `aliases`，精确命中最多返回 10 条；0 条或多条时附 `note` 提示改写或询问。
- `getGoals`、`getHealthSnapshot`、`getGoalRecommendation`：无参数，读当前会话日期。
- `getBodyComposition`：可选 `days`（1–365，默认 30）。返回最近一次称重的全部身体成分指标（名称、数值、单位、是否估算、判定）与体脂率来源（`scaleReading` 秤读数 / `calibrated` 校准公式 / `estimated` BMI 估算），`days` 天内每次称重的体重、体脂率、去脂体重、肌肉量及截至该次的 7 天均值，以及校准状态。时间是本地 ISO 8601。只读，不按会话日期过滤（见《Vita 身体成分模块》）。
- 数值保留一位小数（目标与千卡取整）。

### 手动身体数据与标签图片（client-only 入口）

- `submitManualBodyMetrics`：体重、身高、体脂率、出生日期、生理性别缺失时，由 Onboarding 或设置页表单提交。仅用于目标生成，保存在目标的 evidence snapshot 中，**不写回 HealthKit**。`getHealthSnapshot` 与 `getGoalRecommendation` 返回时标注数据来源。
- `attachNutritionLabel`：用户在 Chat 输入框“+”拍照或从相册选图，发送时客户端先把照片存到本机，再把它按配置缩放后作为 `input_image` 附在这条用户消息里，文字部分注明 `labelScanId`；**本地路径不发送**（TDD §8、ADR-016）。消息以 `label:<scanId>` 引用保存，之后重放历史时照片随之重放。怎么处理标签照片写在系统 prompt 里（可远程调整）：默认意图是存入个人食品库，模型直接调用 `proposeFoodChange`（`source = nutritionLabel`），品牌、包装读不到就留空，不先追问，用户没说吃了多少也不追问用量；仍需 Pending 确认。

## Pending 状态机

```text
none → readyForConfirmation → confirmed
              ├──────────────→ cancelled
              └──────────────→ expired
```

- 澄清（生熟、多候选、用量缺失）发生在聊天中，**不创建 Pending**；只有通过校验、可直接确认的提案才创建 Pending。
- 每个 `sessionDate` 最多一个 `readyForConfirmation` Pending。
- `confirmed` 才会在一个本地事务中修改正式数据，并安排 HealthKit outbox 操作。
- 新的独立写入在 Pending 活跃时被拒绝；查询、澄清、修正和取消被允许。修正会替换 Pending 内容。
- `expiresAt = min(createdAt + 30 分钟, createdAt 所在本地自然日的次日 00:00)`。截止点取决于**创建 Pending 的真实时间**，而不是 `sessionDate`：向历史日期写入时，用 `sessionDate` 次日 00:00 会使 Pending 创建即过期。打开 App、切换日期、进入前台和提交前都必须清理过期项。

## 模型输出要求

模型回复应把“事实”“估算”“需要确认”清楚分开。出现多个营养匹配、会明显改变营养的生熟差异或用量缺失时，优先询问，不得生成看似确定的 Pending。
