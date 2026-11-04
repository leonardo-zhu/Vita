# 诊断日志 Schema

[`batch.schema.json`](batch.schema.json)：客户端上报到 Vita Admin `POST /api/ingest/events` 的批次格式（Vita Admin 设计 §11.4、ADR-014）。Admin 按它校验并拒绝多余字段；iOS 的编码测试按它检查。

只有元数据，不含 prompt、消息、饮食、健康数据或任何自由文本。

2.0 起对话在服务端跑，iOS 不再记 `chat_turn` 与 `tool_call`（对话追踪改由 API 写进 `chat_traces`，见《Vita 2.0 架构设计》§10.3）；iOS 只剩 `config_fetch`。schema 保留这两种事件，Admin 仍能显示旧数据。

| 事件 | 什么时候记 | 关键字段 |
| --- | --- | --- |
| `chat_turn` | 一轮对话结束（保存、失败或取消） | `outcome`、`errorCode`、`latencyMs`、`rounds`、`toolCalls`、`tokensIn/Out`、`createdPending`、`claimedCardWithoutTool`、`hitMaxRounds` |
| `tool_call` | 手机上执行完一个工具 | `tool`、`resultCode`（`ok` 或工具返回的错误码）、`latencyMs` |
| `config_fetch` | 一次远程配置检查 | `outcome`（`updated` / `unchanged` / `failed`）、`errorCode` |

所有事件都带 `eventId`（去重用）、`occurredAt`、`dataClass`（目前只有 `diagnostic`）和生效的 `configVersion`。批次带轮换的匿名 `installId`（30 天换一次）、App 版本与系统版本。
