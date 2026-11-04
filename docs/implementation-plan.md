# Vita MVP 实施计划

> **2.0 说明（2026-11-04）：** 本文是 1.0（本地优先）的实施记录，Phase 0–5 的状态按当时写成，不再改。2.0 把数据与 Agent 搬到了 Vita API，iOS 里的 SwiftData 业务库、`RecordService`、`ChatOrchestrator`、`LLMClient`、调试覆盖与样例数据都已删除或改为调 API；2.0 的分期与进度见《Vita 2.0 架构设计》§16，下面“剩余工作”按 2.0 的现状更新过。

每个阶段都应有可手工验收的最小闭环；不以“接上模型”为由跳过本地数据正确性与同步测试。

## Phase 0：项目基础

- 创建最低部署版本为 iOS 17 的 SwiftUI 工程，配置 SwiftLint（可选）与 XCTest。
- 建立 Feature / Domain / Data / Platform 分层，初始化 SwiftData container、Keychain 和依赖注入。
- 加入文档中定义的领域值类型和迁移策略。
- iOS 工程位于 `ios/`；加入内置默认配置与 `ConfigProvider` 协议（内存实现用于测试），模型调用统一走 `LLMClient`，不内置上游 Provider 直连。

验收：冷启动可创建空数据库；单元测试可使用内存 store。

状态（2026-10-30）：完成。内置默认配置在 `ios/Vita/Resources/DefaultConfig.json`，`ConfigProvider` 按字段合并三层并记录来源（`LayeredConfigProvider` 兼作测试用内存实现）；Conduit 地址由 `project.yml` 的 `CONDUIT_BASE_URL` 按 Debug / Release 设置，目前两者都指向唯一的生产实例；Keychain 存 Conduit 令牌（`conduit.token`）。远程配置 schema 见 `shared/config-schema/config.schema.json`。

## Phase 1：本地领域与 Data

- 实现 Session、ChatMessage、Record、Item、Food Product / Version、Goal 与公共参考库读取。
- 加入一份**测试用小型参考库 fixture**（十余条，含生/熟鸡胸肉等多候选情形，不含任何中国来源真实数据），使本阶段与 Phase 2 不依赖 Phase 3 的正式构建。
- 实现营养计算、日汇总、日期导航和只读 Data 页面。
- 实现时间精度、单位标准化与 Revision 校验。

验收：不依赖模型即可通过 fixture 创建、修改、删除记录；当天总营养和目标完成度正确更新。

状态（2026-10-30）：完成。写入经 `RecordService`（create / appendItems / replaceItem / removeItem / delete，单事务、revision 校验、成功与失败都记审计）；目标经 `GoalService`（只追加）；只读 Data 页（日期切换、摄入与目标、记录详情）。参考库 fixture 在 `ios/VitaTests/Fixtures/`，正式构建产物不存在时 App 以空库运行。Debug 构建可用启动参数 `-VitaSeedSampleData` 在今天写入样例数据。Food Product / Version 只建了模型，创建与版本流程留在 Phase 3；ChatMessage 只有模型，读写随 Phase 5。必测场景 1、2、6 已有单元测试。

## Phase 2：确认式记录流程

- 实现 PendingStore、确认卡片、取消、替换、TTL 与跨天清理。
- 以假 Agent（fixture JSON）驱动所有 create / append / replace / delete 分支。
- 写入审计日志，验证过期 Pending 不产生正式数据。

验收：同一日期只能有一个活跃 Pending；重启后未过期 Pending 可恢复；跨午夜/30 分钟后自动取消。

状态（2026-10-30）：完成。`PendingService` 负责提案、确认、取消与过期：提案与正式写入共用 `RecordService` 的同一套校验，确认时核对 payload 哈希与 revision，并在同一事务里写入记录、标记 Pending；修正须带 `replacesPendingId`。`ProposalToolHandler` 解析 `proposeRecordChange` / `proposeRecordDeletion` 的参数（格式见 Agent 工具契约），日期不符时返回 `requiresDateSwitch`。Chat 页暂时只显示当天的确认卡（iOS 26 起用 Liquid Glass），Debug 构建右上角“假 Agent”菜单可发出各类提案；单元测试由 `VitaTests/Fixtures/agent-script.fixture.json` 驱动全部分支。必测场景 3、5、7 已覆盖。

## Phase 3：Nutrition DB 与标签录入

- 实现 Food Product、不可变 Food Version、包装规格和引用快照。
- 加入本地图片存储，所有解析结果走确认卡。
- 按《公共营养参考库规范》构建首批公共营养 JSON、中文别名与精确查询：中国来源数据（用户本地私有输入，Git 忽略）优先，USDA FoodData Central 补充中国库未覆盖的食材。
- 实现 `attachNutritionLabel`：照片存本机并随消息发给模型读取（2026-11-02 起，ADR-016；最初是本机 OCR 只发识别文字）。

验收：历史 Item 的营养结果不随 Food Version 更新而改变；AI 估算不能被直接保存为个人食品版本。

状态（2026-10-30）：客户端部分完成，正式参考库构建待做。`FoodService` 管理 Food Product 与不可变 Food Version，新建产品与新版本都经 Pending 确认，新版本让旧版本退役，提案后生效版本变化则作废；`packageConversion` 用量必须对应带包装规格的个人食品。`LabelScanService` 实现 `attachNutritionLabel`：原图存 App Support（最初在本机用 Vision 识别、`NutritionLabelParser` 解析；2026-11-02 改为照片直接发给模型读，见 ADR-016）。`proposeFoodChange` 的来源只接受营养标签（须指向本机保存的标签照片 ID）、用户提供或公共参考库（数值由客户端复制），AI 估算被拒绝。Data 页新增只读的营养库与参考库署名。正式参考库：`tools/reference-food/build.py` 从本地私有数据构建 `reference-foods.json`，中国食物成分表（Sanotsu 矫正版 JSON）优先、USDA FoodData Central（Foundation 2026-10-29 / SR Legacy 2018-04）补充，同一 Vita ID 以中国条目为准；精选层 85 条（中国 62、USDA 23）加中国数据自动整理的扩展层，精选层未命中时才查扩展层。已知缺口：中国数据不含调味品，酱油、白砂糖、蜂蜜暂用 USDA。

## Phase 4：HealthKit 与目标

- 实现读权限、缺失数据兜底（含 `submitManualBodyMetrics`）、`getGoalRecommendation` 预览 + `commitInitialGoals` 一次性确认，以及 `updateGoal` 明确指令更新（保留旧行，可用指令改回）。
- 实现 HealthKit outbox、UUID mapping、修改替换、删除撤销和权限撤销提示。
- 在模拟 HealthKit adapter 中覆盖失败与重试情形。

验收：同一 Record 多次修改后 HealthKit 只有最新版 Sample；无写入权限时本地记录仍正确且显示待解决同步状态。

状态（2026-10-31）：完成。`HealthKitDataStore` 只请求 PRD 所列 7 项读取与 4 项膳食写入，测试用 `FakeHealthDataStore`（可注入失败与权限状态）。`HealthService` 读取各项并区分有数据 / 无数据 / 读取失败，缺失项由 `submitManualBodyMetrics` 补录兜底（只用于目标，不写回 HealthKit）。`GoalRecommendationPolicy` 实现 Mifflin–St Jeor、TDEE（活动能量或 ×1.375 估算）、能量 90% 与蛋白 1.8 g/kg；`commitInitialGoals` 保存建议作为 evidence，`updateGoal` 只改给出的项并返回旧值与新值。`HealthSyncService` 在 Record 同一事务里登记 outbox，同步时先删映射里的旧 Sample 再写新 Sample，每条记录只执行最新一次操作；删除失败保留映射，未授权保持待同步，被拒绝标为需要用户处理。Data 页新增健康卡片、目标设定与记录同步标记。“还可以吃”= 目标 − 已摄入，活动消耗只作参考，避免与 TDEE 重复计算。场景 4 已覆盖。工具层（`getHealthSnapshot`、`getGoalRecommendation`、`updateGoal`）的模型接入随 Phase 5。

## Phase 5：Agent 接入与体验打磨

- 以 `LLMClient` 接入 Conduit（Responses API，无状态），启用工具调用；前置：Conduit M1 可用（令牌鉴权、别名路由）——2026-10-29 已上线，开始时在 Conduit 的应用 Vita 下配别名（如 `vita-chat`）、每台设备建一把密钥。
- 完成远程配置拉取、校验与本地调试覆盖（见 Vita Admin 设计）；Admin 与诊断日志按其分期 M1–M3 推进，不阻塞本阶段的真实对话验收。
- 为工具参数、模型输出、超时和网络错误增加校验与可恢复提示。
- 实现 Chat / Data 双层导航、按日 Session、Onboarding。

验收：使用真实对话完成“记录、确认、查看、修正、删除”全链路，且所有写入均通过确认门。

状态（2026-11-01）：完成，远程配置的服务端尚未部署；真实对话验收已通过（模拟器，经 Conduit 别名 `vita-chat`：记录 → 澄清生/熟与用量 → 确认 → Data 页查看 → 修正 → 删除，每次写入都经确认卡）。

- **模型接入**：`ResponsesClient`（`URLSession` + SSE）实现 `LLMClient`，细节见 Provider 规范 §7。
- **工具**：`AgentToolCatalog` 定义契约里的 11 个工具与参数 schema（远程配置只能换描述）；`AgentToolRunner` 执行只读工具与 `updateGoal`，Propose 工具交给 `ProposalToolHandler`。
- **对话编排**：`ChatOrchestrator` 的上下文、工具循环与保存规则见 TDD §3.4。个人食品库整库进上下文，由模型做语义匹配（ADR-016）。
- **Chat 页**：按日期组织会话（日历切换、跨午夜跟随今天、模型提到别的日期时给出切换按钮）；生成中显示推理摘要与工具步骤；确认卡在输入框上方，历史消息标出卡片结局；营养标签可拍照或从相册附上（契约 `attachNutritionLabel`）。
- **设置页**：Conduit 令牌（Keychain，显示末四位）；连点版本号五次打开本地调试覆盖（模型别名、超时、系统 prompt，显示每项来源）；可重新查看首次引导。
- **Onboarding（PRD §3.7）**：欢迎 → 连接 Apple 健康（被拒时说明去哪打开，不阻塞）→ 生成每日目标（与 Data 页共用 `GoalSetupForm`）→ 完成；每步可跳过，已有目标的用户不显示。
- **内置系统 prompt v3**：确认卡只能来自提案工具；思考用中文。验收中模型两次只说“已生成确认卡”却没调用工具，已用历史注记与这条规则缓解。
- 调试用的假 Agent 菜单已删除。

- **远程配置（2026-11-01）**：`RemoteConfigService` 在启动、回到前台与设置页“立即刷新”时用 ETag 检查，校验通过才生效；设置页显示生效版本与上次检查结果。工具描述移进 `DefaultConfig.json`。见 Vita Admin 设计 §14。

未做：诊断日志上报、PRD 中“减脂 / 增肌”的目标类型选择（目标仍按 `GoalRecommendationPolicy` 的固定系数）。

## 剩余工作

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| Vita Admin 首次发布 | 待做 | 已部署到 R4S（Vita Admin 设计 §14）。填管理员密码哈希、登录并注册 Passkey、发布第一版配置。2.0 起配置由 Vita API 读取，发布后看下一轮对话的追踪里配置版本是否变了即可，不用再在手机上刷新。 |
| Admin 多语言与分页（2026-11-02） | 完成，已部署 | 界面文案移到 `admin/src/i18n/messages.ts`（中文 / 英文，类型保证键一致），顶栏和登录页有语言切换（跟随系统 / 简体中文 / English，存 cookie `vita_admin_lang`）；“试跑”改名为“Prompt 调试”，路由 `/admin/playground`；诊断页“最近的事件”最多取 500 条、前端每页 20 条。服务端只返回错误码（校验、Passkey、发布、试跑），文字由界面按语言生成。本地各页面中英文都走过一遍；顺带修了诊断页因 SQLite 行对象无法传给客户端组件而打不开的问题。33 个单测通过。 |
| Vita Admin 收尾 | 部分完成 | M1–M3 都已实现（Vita Admin 设计 §14–§16）。2026-11-04 在 R4S 的 `.env` 配好了 Conduit 密钥（Prompt 调试可用）与调 API 的服务令牌（“设备”页可用）。还要：发布第一版配置；确认诊断日志能到达 Admin。 |
| 标签照片交给模型 + 模型参数远程可调（2026-11-02） | 完成 | 照片随消息发给模型读，不再本机识别（ADR-016）；远程配置加 `llm.reasoningEffort`、`llm.extraBody`、`labelImage`（ADR-017），Admin 配置页与 Prompt 调试同步；每轮客户端状态改为系统消息放在用户消息前，系统指令只留 prompt 与个人食品库，便于命中服务商缓存，诊断日志加 `tokensCached`、诊断页显示命中率。标签照片的处理要求从客户端写死的附件文字移到系统 prompt（v4），去掉了“吃了多少告诉我”的固定结尾。 |
| 诊断日志上报 | 2.0 停用 | 1.0 有对话、工具、配置拉取三类元数据事件，设置页可关（Vita Admin 设计 §16）。2.0 对话在服务端，对话追踪由 API 记录；iOS 不再拉配置后上报一并删除，Admin 诊断页只剩历史数据。 |
| 真机验证与 1.0 迁移 | 完成（2026-11-04） | 2.0 的 App 在模拟器上对本机 API 验证过连接、迁移的导出 / 导入 / 核对 / 中断续做、Chat 出错回填、Data 页（iOS 18.4）。iPhone 上已签发设备令牌、装新版、跑完迁移（3 条记录、3 个食品、14 条消息、4 次称重，服务端核对一致），Apple 健康里饮食与体重没有重复；批量录入标签已用真实模型跑通。iOS 27.1 模拟器的 healthd 不响应 HealthKit 同步授权查询，App 会卡住（1.0 同样），模拟器调试请用 iOS 18.4。 |
| 模型未调用工具却声称已生成确认卡 | 已处理（2026-11-05） | 服务端检测到“回复说生成了卡片但没有 Pending”时提醒模型一次再调用工具；仍没调用就在回复后注明没有生成卡片。历史里的旧照片不再重发，减少干扰；被带偏的上下文可在 Admin“对话”页排除（rewind）。 |
| 本地数据上传到 Admin 用于调试 | 并入 2.0（2026-11-04） | 2.0 改为服务端为唯一数据源，对话追踪随之进 Admin，见《Vita PRD v2.0 草案》。以下为原讨论： 目的：改了 prompt / 参数后能在 Admin 看到实际效果。会改变 ADR-003（业务数据不出设备）与 ADR-014（诊断只含元数据），定了要补新 ADR。候选：A. 对话追踪（每轮原话、回复、推理摘要、工具调用参数与结果、生成的卡片及确认/取消结局，可选带标签照片；设置里可关，Admin 新增“对话”页，按配置 / prompt 版本筛选）；B. 数据快照（记录、营养库、目标只读上传）；C. 完整云同步（不建议）。倾向先做 A。待定：范围（A 或 A+B）、是否带标签照片、保留期（现诊断为 30 天）。 |
| 钠 | 完成（2026-11-05，2.0 M5） | 钠、饱和脂肪、糖作为可选项存储、显示并写入 Apple 健康，见《Vita 2.0 架构设计》§16 M5；上限目标待定。 |
| 钠（原讨论） | 并入 2.0（2026-11-04） | 见《Vita PRD v2.0 草案》§4.3。原讨论： 标签按 GB 28050 必有钠，模型也读得出，但 Food Version 只存四项。要存就要全链路：版本与参考库加可选钠、日合计标明缺数据的条目、写 Apple 健康 `dietarySodium`（新权限）、目标是否加钠上限。 |
| 目标类型（减脂 / 增肌 / 维持） | 完成 | 目标设定与 `updateGoal` 都支持，能量按类型的比例或千卡调整（ADR-018）。 |
| 分发前的令牌 | 2.0 已解决 | 手机不再持有 Conduit 密钥，改用 Admin 签发、可吊销的 Vita 设备令牌（《Vita 2.0 架构设计》§8）；Conduit 密钥只在 API 与 Admin 的 `.env`。 |
| 对话慢（2026-11-04 实测） | 部分处理（2026-11-05） | 确认后的接续（2026-11-05，用真实规模的请求各跑 20 次）：不强制调工具时三种思考档位都只有约 70% 真的出卡，其余只说“现在记……”；加 `tool_choice: required` 后 low 为 19/20、关思考只有 11/20（上游没严格执行 required），所以接续第一轮用 required、保留 low 思考，仍没调工具就提醒一次。已做：出卡成功后直接结束这一轮（每张卡省一次调用，约 10–15 秒，prompt v7 要求说明写在调用提案工具之前）；历史里的旧照片不再重发。实测（2026-11-05）：思考不是瓶颈，真实对话每轮推理只有几百字；`reasoning.effort: minimal` 与 `thinking: disabled` 都能把推理降到 0，但 minimal 下 3 次里有 1 次该调工具没调，所以仍用 `low`；`thinking: auto` 被上游拒绝（400）。原记录： 批量录入 3 张标签时每轮约 39 秒，时间几乎都在模型：`vita-chat` 指向 `ark-code-latest`，每次调用约 2 万 token 输入（含照片）要 12–17 秒才出第一个字（Conduit `usage_logs` 的 `first_token_ms`）；同一上游的 `doubao-seed-2.1-lite` 处理 3.2 万 token 只要 1–2 秒。每张卡还要两次调用（出卡一次、卡片后说一句话又一次，约 15 秒）。Vita 自己的开销不到 1 秒。可选：给 Vita 应用加别名试 `doubao-seed-2.1-lite` 对比准确度；出卡成功后直接结束这一轮、由服务端拼回复。 |
| iOS 远程配置代码 | 完成（2026-11-05） | iOS 的远程配置与诊断上报代码已删除；`DefaultConfig.json` 挪到 `shared/config/`，API、Admin、CI 的引用已改。 |

## 必须覆盖的测试场景

1. 生/熟鸡胸肉同时命中时必须澄清，不能选一个写入。
2. “2 个鸡蛋、共 108g”以 108g 计算并保留原始表达。
3. “昨天吃了…”在今天 Session 中只提出切换，不写昨天数据。
4. 修改或删除已同步 Record 时，先删除旧 HK Sample 再写新 Sample / 清映射。
5. Pending 过期、切换到次日、App 重启与 Revision 冲突均不产生幽灵写入。
6. 个人 Food Version 更新后，旧 Consumption Item 保持原营养快照。
7. 在历史日期 Session 中创建的 Pending，`expiresAt` 为创建后 30 分钟（或当天午夜，取较早者），不会创建即过期。
