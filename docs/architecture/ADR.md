# Vita 架构决策记录（ADR）

本文记录当前技术基线中的决定。`已采纳` 表示可按此继续设计。目前所有决策均已采纳或修订采纳，没有待确认项；若新增 `待确认` 决策，表示已给出推荐方案，但不应在编码时把它当成不可变约束。

| ID | 决策 | 状态 | 结论与理由 |
| --- | --- | --- | --- |
| ADR-001 | 客户端技术栈 | 已采纳 | 使用 Swift + SwiftUI + Swift Concurrency。产品为个人 iPhone 应用，HealthKit 与本地优先体验均适合原生实现。 |
| ADR-002 | 本地持久化 | 已采纳 | 使用 SwiftData，外层保留 Repository / Service 边界。MVP 的数据量小、关系明确；隔离持久化 API 使未来切换 SQLite/GRDB 不影响业务层。 |
| ADR-003 | 服务端 | 已采纳 | MVP 不建设业务后端、账号或云同步。所有业务数据留在设备；模型请求是唯一的可选网络出口。 |
| ADR-004 | Agent 写入权限 | 已采纳 | LLM 不拥有直接写入业务库或 HealthKit 的能力。它只能查询、澄清和生成变更提案；客户端确认后由确定性服务执行写入。 |
| ADR-005 | Agent Provider | 已采纳 | 首个实现使用火山方舟 OpenAI 兼容 Responses API，用户自己的 Ark API Key 存入 Keychain，客户端以 `URLSession` 实现 Responses + SSE + function calling；不引入第三方 Swift OpenAI SDK。`LLMClient` 协议保留，未来可加 BFF 或其他兼容 Provider。详情见《模型 Provider 集成规范》。 |
| ADR-006 | 公共营养库 | 已修订采纳 | 面向中国日常食材时，使用用户本人私有提供的《中国食物成分表》衍生数据作为本地个人构建输入；它不提交到仓库、不公开分发、不用于 TestFlight/App Store 或他人设备。USDA FoodData Central 是可自由内置的补充来源，用于中国库未覆盖的通用/国际食材。品牌食品仍进入个人 Nutrition DB。详情见《公共营养参考库规范》。 |
| ADR-007 | 最低系统版本 | 已采纳 | 最低部署版本为 iOS 17；开发使用当前 Xcode / iOS SDK。SwiftData 自 iOS 17 可用，Vita MVP 不依赖 iOS 18 及以上的专属能力。 |
| ADR-008 | Pending 持久化 | 已采纳 | Pending 是本地临时实体，不是正式 Consumption Record。用独立存储保存、带过期时间和 Session 日期；确认前不生成正式记录，也不触发 HealthKit 写入。 |
| ADR-009 | HealthKit 同步 | 已采纳 | 保存 Vita Record 与每个已写入 HK Sample UUID 的映射，并以 outbox 串行执行写入、替换和删除，避免日总量重复累积。 |
| ADR-010 | 审计 | 已采纳 | 保留本地技术审计日志，记录操作、结果、对象 ID 和错误；不提供用户回滚 UI，也不默认保存完整自由文本提示词。 |
| ADR-011 | 摄入时间默认与 HealthKit 写入 | 已采纳 | 用户完全未表达时间时，默认以录入当下的本地时刻作为摄入时刻，并标记为 `defaultedEntryTime`；明确表达的“午餐/晚上/仅日期”保留原始精度。后者同步 HealthKit 时使用代表性时间并写入精度 metadata；Vita 自身不把代表性时间显示为用户陈述的事实。 |

## 实现前置条件

中国食物成分数据仅限用户本人本地构建与个人设备使用；不得提交进仓库、公开分发或用于 TestFlight/App Store。若范围改变，须重新核验授权。
