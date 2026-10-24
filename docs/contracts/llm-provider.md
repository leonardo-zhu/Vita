# Vita 模型 Provider 集成规范

**状态：已采纳**  
**对应决策：** ADR-005  
**首个 Provider：** 火山方舟（Volcengine Ark）

## 1. 决策

首个实现使用火山方舟的 OpenAI 兼容 **Responses API**：

```text
POST https://ark.cn-beijing.volces.com/api/v3/responses
Authorization: Bearer <ARK_API_KEY>
Content-Type: application/json
```

火山方舟已提供 Responses API 的 function calling 文档和 OpenAI SDK 兼容示例。Vita 不依赖某个社区 Swift OpenAI SDK，而是用 iOS 标准库 `URLSession`、`Codable` 和 Swift Concurrency 写一个小型、受测试覆盖的协议适配器。

这是刻意选择：官方 OpenAI SDK 当前列出 Python、JavaScript/TypeScript、.NET、Go、Java 与 Ruby，但没有官方 Swift SDK；第三方 Swift 包也未必完整实现火山方舟当前的 Responses 事件与工具调用语义。自建的薄适配层比引入一个 API 跟随速度不确定的依赖更可控。

## 2. 与 Node.js 的对应关系

| Node.js / TypeScript | Vita Swift |
| --- | --- |
| `new OpenAI({ baseURL, apiKey })` | `ArkResponsesClient(baseURL, apiKeyProvider)` |
| `client.responses.create()` | `URLSession.data(for:)` + `Codable` request/response DTO |
| AsyncIterable SSE stream | `URLSession.bytes(for:)` 的逐行 SSE parser / `AsyncThrowingStream` |
| Zod schema + runtime validation | `Codable` 解码 + 显式参数校验 |
| provider adapter interface | `LLMClient` Swift protocol |
| server-side secret / environment variable | 用户本人 API Key 存 Keychain |

## 3. 配置与密钥

| 配置 | 保存位置 | 规则 |
| --- | --- | --- |
| `ARK_API_KEY` | Keychain | 只由用户在 Settings 输入；不进 SwiftData、UserDefaults、日志、截图或测试 fixture。 |
| Base URL | 编译配置默认值 | 默认 `https://ark.cn-beijing.volces.com/api/v3`；未来可由兼容 Provider 配置覆盖。 |
| Model ID | 用户偏好（非敏感） | 使用用户在方舟中已开通的模型/推理端点 ID；不在源码硬编码具体模型名称。 |
| 超时、重试和流式开关 | 用户偏好/应用默认值 | 只重试尚未产生可观察工具副作用的网络请求。 |

这是个人自用的 BYOK（bring your own key）模型：用户故意把自己的 Ark Key 授予自己的设备。它不适合把一个共享平台 API Key 打进公开发布的 App；若未来需要共享密钥、配额控制或服务端任务，再引入 BFF。

## 4. 客户端协议边界

```text
ChatOrchestrator
  → LLMClient (domain protocol)
  → ArkResponsesClient (URLSession adapter)
  → Ark Responses API
```

`LLMClient` 应只暴露三类能力：普通响应、流式响应、带工具循环的响应。上层不认识 URL、Bearer header、SSE event 名称或 Ark DTO。

每次请求都由客户端构造：当前 `sessionDate`、已裁剪的对话上下文、工具定义和 `requestId`。不能把整个 SwiftData 数据库、全部 HealthKit 原始历史、API Key 或标签原图默认发送给模型。

## 5. 工具循环

```text
1. 本地构造 Responses request（input + tools）
2. Ark 返回文本，或一个/多个 function_call
3. 客户端按 Agent 工具契约执行只读/propose 工具
4. 客户端把 function_call_output 送回同一轮续答
5. 模型生成说明、澄清问题或 Pending 卡片内容
6. 用户点击确认，客户端直接调用 confirmPending；模型不参与提交
```

只允许 [Agent 工具契约](agent-tools.md) 定义的工具。`confirmPending`、`cancelPending`、HealthKit 同步、Keychain 和任意直接数据库 mutation 都是 client-only，绝不可作为模型 function 暴露。

优先由 Vita 在本地维护会话上下文，不把 `previous_response_id` 当作跨请求的唯一真相。这样切换 Provider、离线查看历史或清除远端会话状态时都不会破坏 Vita 的业务记录。

## 6. 兼容性与验证

“OpenAI 兼容”不是自动等价。首个实现只承诺火山方舟已验证的 Responses API、SSE 流式文本与 function calling；增加其他 Provider 前要用同一套 fixture contract tests 验证：

- 正常文本响应和流式文本拼接；
- 一个与多个 `function_call`；
- `function_call_output` 回传后续答；
- 结构错误、超时、取消和非 2xx 响应；
- 不能通过模型响应绕过 Pending 确认门；
- API Key 不出现在 error、审计或网络诊断日志。

App 将响应 ID、模型 ID、请求耗时、token/费用字段（若 API 返回）作为最小诊断信息保存，但不保存 API Key 或完整敏感 payload。Provider 的远端存储/保留选项必须以方舟当时文档为准，在设置页明确展示；Vita 不依赖远端状态保存本地会话。
