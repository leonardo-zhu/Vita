# Vita 架构决策记录（ADR）

本文记录当前技术基线中的决定。`已采纳` 表示可按此继续设计。目前所有决策均已采纳或修订采纳；若新增 `待确认` 决策，表示已给出推荐方案，但不应在编码时把它当成不可变约束。

| ID | 决策 | 状态 | 结论与理由 |
| --- | --- | --- | --- |
| ADR-001 | 客户端技术栈 | 已采纳 | 使用 Swift + SwiftUI + Swift Concurrency。产品为个人 iPhone 应用，HealthKit 与本地优先体验均适合原生实现。 |
| ADR-002 | 本地持久化 | 已采纳 | 使用 SwiftData，外层保留 Repository / Service 边界。MVP 的数据量小、关系明确；隔离持久化 API 使未来切换 SQLite/GRDB 不影响业务层。 |
| ADR-003 | 服务端 | 已修订采纳 | MVP 不建设业务后端、用户账号或云同步。所有业务数据留在设备。~~模型请求是唯一的可选网络出口。~~ 网络出口为三个：经 Conduit 的模型请求、远程配置拉取、可关闭的诊断日志上报（见 ADR-012 / 013 / 014）；配套服务 Vita Admin 与 Conduit 不存储业务数据。 |
| ADR-004 | Agent 写入权限 | 已采纳 | LLM 不拥有直接写入业务库或 HealthKit 的能力。它只能查询、澄清和生成变更提案；客户端确认后由确定性服务执行写入。 |
| ADR-005 | Agent Provider | 已采纳，部分被 ADR-013 取代 | 首个实现使用~~火山方舟~~ OpenAI 兼容 Responses API，~~用户自己的 Ark API Key 存入 Keychain，~~ 客户端以 `URLSession` 实现 Responses + SSE + function calling；不引入第三方 Swift OpenAI SDK。`LLMClient` 协议保留，~~未来可加 BFF 或其他兼容 Provider~~（Conduit 即该网关，见 ADR-013）。详情见《模型 Provider 集成规范》。 |
| ADR-006 | 公共营养库 | 已修订采纳 | 面向中国日常食材时，使用用户本人私有提供的《中国食物成分表》衍生数据作为本地个人构建输入；它不提交到仓库、不公开分发、不用于 TestFlight/App Store 或他人设备。USDA FoodData Central 是可自由内置的补充来源，用于中国库未覆盖的通用/国际食材。品牌食品仍进入个人 Nutrition DB。详情见《公共营养参考库规范》。 |
| ADR-007 | 最低系统版本 | 已采纳 | 最低部署版本为 iOS 17；开发使用当前 Xcode / iOS SDK。SwiftData 自 iOS 17 可用，Vita MVP 不依赖 iOS 18 及以上的专属能力。 |
| ADR-008 | Pending 持久化 | 已采纳 | Pending 是本地临时实体，不是正式 Consumption Record。用独立存储保存、带过期时间和 Session 日期；确认前不生成正式记录，也不触发 HealthKit 写入。 |
| ADR-009 | HealthKit 同步 | 已采纳 | 保存 Vita Record 与每个已写入 HK Sample UUID 的映射，并以 outbox 串行执行写入、替换和删除，避免日总量重复累积。 |
| ADR-010 | 审计 | 已采纳 | 保留本地技术审计日志，记录操作、结果、对象 ID 和错误；不提供用户回滚 UI，也不默认保存完整自由文本提示词。 |
| ADR-011 | 摄入时间默认与 HealthKit 写入 | 已采纳 | 用户完全未表达时间时，默认以录入当下的本地时刻作为摄入时刻，并标记为 `defaultedEntryTime`；明确表达的“午餐/晚上/仅日期”保留原始精度。后者同步 HealthKit 时使用代表性时间并写入精度 metadata；Vita 自身不把代表性时间显示为用户陈述的事实。 |
| ADR-012 | 远程配置与 Vita Admin | 已采纳 | 采用三层配置（本地调试覆盖 > 远程配置 > 内置默认值）。配置由 Vita Admin（`admin/`，Next.js + SQLite，部署在 R4S）编辑、校验后发布为静态 JSON，由 R4S 上的 Caddy 直接提供，Admin 进程不在请求路径上；客户端在启动与每次回到前台时用 ETag 检查。现阶段不签名，只认构建配置里的唯一 HTTPS 地址，分发前重新评估。远程配置只能改 prompt、模型别名与运行参数，不能改确认门、工具 schema、Conduit 地址与写入规则。详情见《Vita Admin 设计》。 |
| ADR-013 | 模型网关 Conduit | 已采纳（2026-10-29 上线） | 客户端所有模型调用统一经独立项目 Conduit（`/v1/responses`，无状态子集），不直连上游、不内置 Provider 档案、不持有上游 Key；以 Conduit 令牌鉴权，现阶段为 Conduit 管理有效期与额度的固定令牌，分发前改为设备注册。取舍：没有直连逃生口，Conduit 可用性即 Agent 可用性。详情见《Conduit 项目设计》与《模型 Provider 集成规范》。 |
| ADR-014 | 诊断日志上报 | 已采纳 | 客户端可向 Vita Admin 上报诊断日志，仅含元数据（错误码、配置版本、耗时、token 数、轮换的匿名安装 ID），可在设置页关闭，现阶段默认开（分发前加首次启动告知并重新评估）。事件格式见 `shared/diagnostics/`，实现见《Vita Admin 设计》§16。当前阶段不上传对话、饮食、健康数据和图片；将来如需备份或数据收集，须另立 ADR、独立同意开关、独立存储与保留期。 |
| ADR-015 | 个人食品库匹配 | 已采纳（2026-10-31） | 客户端不对个人食品库做字符串或模糊匹配。整库结构化摘要放进系统上下文，`searchPersonalFoods` 也返回整库，由模型按语义判断用户说的是哪一个，有歧义先问（PRD §3.1 设计要点）。公共参考库体量大，仍按规范名与别名精确匹配。取舍：个人库内容（品名、营养）会随请求发给 Conduit；库变大到影响上下文时再改为分段或检索。 |
| ADR-016 | 营养标签由模型看图识别 | 已采纳（2026-11-02） | 标签照片随用户消息以 `input_image` 发给模型，由模型读出数值，取代最初的本机 Vision 识别 + 规则解析（TDD 原写“本地 OCR + 可选模型解析，原图不默认上传”）。理由：本机识别对小字、倾斜的真实标签不可靠（2026-11-02 圣农鸡腿块标签的名称列整列识别失败），模型读同一张图又快又准；PRD 本来就写“由 Agent 解析”。照片发送前不另弹同意说明，经 Conduit 发往火山方舟，请求带 `store: false`。原图仍存本机作为 Food Version 的来源依据，数值仍须经确认卡；缩放与 `detail` 由远程配置 `labelImage` 调整。 |
| ADR-017 | 模型请求参数远程可调 | 已采纳（2026-11-02） | 远程配置新增 `llm.reasoningEffort`（Responses 的 `reasoning.effort`，`default` 表示不传）与 `llm.extraBody`（原样合并进请求体的其他参数，如 `max_output_tokens`、`max_tool_calls`、`thinking`、`prompt_cache_key`；不能覆盖 `model`、`input`、`tools`、`stream`、`store` 等客户端字段）。理由：各模型支持的参数与档位映射不同、还会变（实测当前模型拒绝 `temperature` / `top_p`），逐个加字段客户端总会落后；Prompt 调试用同一套参数，模型不接受时在发布前就能看到 400。内置默认推理强度为 `low`。 |

## 实现前置条件

中国食物成分数据仅限用户本人本地构建与个人设备使用；不得提交进仓库、公开分发或用于 TestFlight/App Store。若范围改变，须重新核验授权。
