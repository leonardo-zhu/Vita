# Vita 模型 Provider 集成规范

**状态：已采纳并实现，部分被取代（见 ADR-013）**  
**实现：** ~~`ios/Vita/Platform/LLM/`（`LLMClient`、`ResponsesClient`），契约测试见 `ios/VitaTests/ResponsesClientTests.swift`。~~ 2.0 起调用方是 Vita API：`api/src/agent/llm.ts`（同一套 Responses + SSE + function calling，TypeScript 实现），测试见 `api/src/agent/agent.test.ts`；iOS 的实现已删除，手机不再持有 Conduit 令牌（ADR-019）。2026-10-31 经 Conduit 别名 `vita-chat` 完成真实对话验收（1.0），2026-11-04 在服务端用真实模型再次跑通。

> **2.0 阅读说明：** 下文的“客户端”指调 Conduit 的一方，2.0 起是 Vita API；Conduit 密钥存在 API 的 `.env`（不是 Keychain），超时、别名等仍来自生效配置（API 读 Admin 发布的 `stable.json`）。  
**对应决策：** ADR-005（部分被 ADR-013 取代）  
**当前上游：** 经 Conduit 网关访问（上游目前为火山方舟 Volcengine Ark）

> **阅读说明：** ~~删除线~~ 内容是原先的 BYOK 直连方舟设计，已被 Conduit 取代，保留是为了追溯版本。紧随其后的是替代内容。未加删除线的部分仍然有效。
>
> 变更摘要：客户端不再直连方舟，也不再持有方舟 API Key；所有模型调用走 Conduit 的 `/v1/responses`，鉴权用 Conduit 令牌。线协议（Responses API + SSE + function calling）、`LLMClient` 抽象与工具循环不变。

## 1. 决策

客户端使用 OpenAI 兼容的 **Responses API** 协议。~~首个实现使用火山方舟的 OpenAI 兼容 Responses API：~~

~~POST https://ark.cn-beijing.volces.com/api/v3/responses~~
~~Authorization: Bearer ＜ARK_API_KEY＞~~

**现行：** 请求发往 Conduit，Conduit 再转发给上游：

```text
POST {CONDUIT_BASE_URL}/v1/responses
Authorization: Bearer <Conduit 访问令牌>
Content-Type: application/json
```

Conduit 对客户端暴露 Responses API 的无状态子集（见 §5、§6）。上游是否原生支持 Responses、是否需要协议转换，是 Conduit 的内部事务。

生产地址 `https://conduit.r4s.leonardo-zhu.me`（2026-10-29 上线，`CONDUIT_BASE_URL` 不带 `/v1`）。还没有单独的开发实例，Debug 构建指向哪里见 Vita Admin 设计 §12 第 8 条。Conduit 已实现的范围见 [Conduit 项目设计](../architecture/llm-gateway-project.md) §0。

Vita 不依赖某个社区 Swift OpenAI SDK，而是用 iOS 标准库 `URLSession`、`Codable` 和 Swift Concurrency 写一个小型、受测试覆盖的协议适配器。

这是刻意选择：官方 OpenAI SDK 当前列出 Python、JavaScript/TypeScript、.NET、Go、Java 与 Ruby，但没有官方 Swift SDK；第三方 Swift 包也未必完整实现 Responses 事件与工具调用语义。自建的薄适配层比引入一个 API 跟随速度不确定的依赖更可控。

## 2. 与 Node.js 的对应关系

| Node.js / TypeScript | Vita Swift |
| --- | --- |
| ~~`new OpenAI({ baseURL, apiKey })`~~ | ~~`ArkResponsesClient(baseURL, apiKeyProvider)`~~ → `ResponsesClient(baseURL, tokenProvider)` |
| `client.responses.create()` | `URLSession.data(for:)` + `Codable` request/response DTO |
| AsyncIterable SSE stream | `URLSession.bytes(for:)` 的逐行 SSE parser / `AsyncThrowingStream` |
| Zod schema + runtime validation | `Codable` 解码 + 显式参数校验 |
| provider adapter interface | `LLMClient` Swift protocol |
| ~~server-side secret / environment variable~~ | ~~用户本人 API Key 存 Keychain~~ → Conduit 访问令牌存 Keychain；上游 Key 由 Conduit 服务端持有 |

## 3. 配置与密钥

| 配置 | 保存位置 | 规则 |
| --- | --- | --- |
| ~~`ARK_API_KEY`~~ | ~~Keychain~~ | ~~只由用户在 Settings 输入；不进 SwiftData、UserDefaults、日志、截图或测试 fixture。~~ |
| **Conduit 访问令牌** | Keychain | 现阶段为 Conduit 签发的固定令牌，在 Settings 输入；有效期、额度和吊销都由 Conduit 管理（令牌被过期或吊销时，客户端收到 401，提示用户更新令牌）。不进 SwiftData、UserDefaults、日志、截图或测试 fixture。分发前将换为设备注册换取的短期令牌（见 Conduit 项目文档 §4）。 |
| ~~Base URL~~ | ~~编译配置默认值~~ | ~~默认 `https://ark.cn-beijing.volces.com/api/v3`；未来可由兼容 Provider 配置覆盖。~~ |
| **Conduit 地址** | 构建配置 | Debug 指向开发实例，Release 指向生产实例。**不可远程改，不可由用户改**（见 Vita Admin 设计 §3.2）。 |
| Model ID | ~~用户偏好（非敏感）~~ → 生效配置（非敏感） | ~~使用用户在方舟中已开通的模型/推理端点 ID；~~ 现为 Conduit 的**逻辑别名**，来自 Vita Admin 下发的生效配置；不在源码硬编码具体模型名称。 |
| 超时、重试和流式开关 | ~~用户偏好/应用默认值~~ → 生效配置/内置默认值 | 只重试尚未产生可观察工具副作用的网络请求。 |
| 推理强度与其他请求参数 | 生效配置/内置默认值 | `llm.reasoningEffort` 映射为 `reasoning.effort`（`default` 不传）；`llm.extraBody` 原样合并进请求体，客户端自己填的字段不能被覆盖（ADR-017）。 |

~~这是个人自用的 BYOK（bring your own key）模型：用户故意把自己的 Ark Key 授予自己的设备。它不适合把一个共享平台 API Key 打进公开发布的 App；若未来需要共享密钥、配额控制或服务端任务，再引入 BFF。~~

**现行：** 客户端不持有任何上游模型 Key。共享密钥、配额控制与 Provider 切换由 Conduit 承担。客户端没有直连上游的路径，因此 Conduit 的可用性就是 Agent 的可用性。

## 4. 客户端协议边界

```text
ChatOrchestrator
  → LLMClient (domain protocol)
  → ResponsesClient (URLSession adapter)      ~~ArkResponsesClient~~
  → Conduit /v1/responses                     ~~Ark Responses API~~
  → 上游 Provider
```

`LLMClient` 应只暴露三类能力：普通响应、流式响应、带工具循环的响应。上层不认识 URL、Bearer header、SSE event 名称或上游 DTO。

每次请求都由客户端构造：当前 `sessionDate`、已裁剪的对话上下文、工具定义和 `requestId`（同时作为 `X-Request-Id` 头，用于与 Conduit 日志关联）。不能把整个 SwiftData 数据库、全部 HealthKit 原始历史或令牌发送给模型；营养标签照片只在用户附上它的那条消息里发送（ADR-016）。

## 5. 工具循环

```text
1. 本地构造 Responses request（input + tools）
2. 模型返回文本，或一个/多个 function_call            ~~Ark 返回~~
3. 客户端按 Agent 工具契约执行只读/propose 工具
4. 客户端把 function_call_output 送回同一轮续答
5. 模型生成说明、澄清问题或 Pending 卡片内容
6. 用户点击确认，客户端直接调用 confirmPending；模型不参与提交
```

只允许 [Agent 工具契约](agent-tools.md) 定义的工具。`confirmPending`、`cancelPending`、HealthKit 同步、Keychain 和任意直接数据库 mutation 都是 client-only，绝不可作为模型 function 暴露。

优先由 Vita 在本地维护会话上下文，不把 `previous_response_id` 当作跨请求的唯一真相。**现行约束：** 请求一律使用无状态模式（`store: false`），Conduit 首期不支持 `previous_response_id`，也不保存会话。这样切换 Provider、离线查看历史或清除远端会话状态时都不会破坏 Vita 的业务记录。

## 6. 兼容性与验证

“OpenAI 兼容”不是自动等价。~~首个实现只承诺火山方舟已验证的 Responses API、SSE 流式文本与 function calling；~~ **现行：** 客户端只承诺 Conduit 对外声明的 Responses 子集（SSE 流式文本、function calling、无状态）。Conduit 增加或更换上游前，要用同一套 fixture contract tests 验证：

- 正常文本响应和流式文本拼接；
- 一个与多个 `function_call`；
- `function_call_output` 回传后续答；
- 结构错误、超时、取消和非 2xx 响应；
- Conduit 统一错误类型的映射：令牌无效或过期（401 `authentication_error`）、额度耗尽（429 `insufficient_quota`）、请求不合法（400 `invalid_request_error`，如带了 `previous_response_id`）、上游停用（503 `upstream_unavailable`）、上游错误（502 `upstream_error`）、上游超时（504 `upstream_timeout`），各自对应不同的用户提示。错误体是 `{ error: { type, code, message } }`；流式过程中出错时以流内 `error` 事件结束；
- 不能通过模型响应绕过 Pending 确认门；
- ~~API Key~~ **Conduit 令牌** 不出现在 error、审计或网络诊断日志。

## 7. 实现说明（2026-10-31）

- **流式事件**：解析 `response.output_text.delta`（正文）、`response.reasoning_summary_text.delta` / `response.reasoning_text.delta`（推理摘要，只在界面展示，不保存、不回传）、`response.output_item.done`（函数调用）、`response.completed` / `response.incomplete`（完成，补发只出现在完成事件里的函数调用）、`response.failed` 与 `error`。流在没有完成事件时结束视为连接中断。
- **非流式**：按 `output` 顺序转成同样的事件序列（`streaming` 由生效配置决定）。
- **请求体**：`store: false`；用户与助手消息用简写形式（`role` + 字符串 `content`），带标签照片的用户消息用 `input_text` + `input_image`（base64 data URL 与 `detail`）分段；每轮的客户端状态是一条 `role: system` 的消息，放在本轮用户消息前；函数调用与输出用 `function_call` / `function_call_output` item 原样回传。推理强度与 `extraBody` 见 §3。
- **缓存**：火山方舟对 seed 2.0 之后的模型自动做前缀缓存（隐式缓存，不可关闭、不收存储费，至少 1024 token 才可能命中），与 `store` 无关；`store` 只决定服务商是否保存回复供之后检索或接 `previous_response_id`。所以请求按“越稳定越靠前”组织：系统指令（prompt + 个人食品库）、工具、历史、本轮客户端状态、本轮消息。命中数取自 `usage.input_tokens_details.cached_tokens`，记入诊断日志 `tokensCached`。需要时可经 `extraBody` 加 `prompt_cache_key` 提高命中率。
- **重试**：只有在尚未产出任何事件时，才按 `llm.maxRetries` 重试可重试错误（502 / 503 / 504 / 网络），间隔 1 秒，避免重复的文字或工具调用。
- **超时**：`URLRequest.timeoutInterval` 取 `llm.timeoutSeconds`；流式时是两次数据之间的最长等待。
- **令牌**：每次请求时从 Keychain 读取，更换令牌不必重启；缺失时不发请求，直接提示去设置。
- **错误提示**：`LLMError.userMessage` 为每类错误给出一句中文提示；401 提示更新令牌，400 显示 Conduit 返回的原因（如别名不存在）。

App 将模型别名、请求耗时、输入 / 输出 / 命中缓存的 token 数作为最小诊断信息，随诊断日志上报（ADR-014），但不保存令牌或完整敏感 payload。~~Provider 的远端存储/保留选项必须以方舟当时文档为准，在设置页明确展示；~~ 现行：请求固定 `store: false`，远端保留策略由 Conduit 的隐私规则约束（默认不记录内容，见 Conduit 项目文档 §7）；Vita 不依赖远端状态保存本地会话。
