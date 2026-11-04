# Agent 工具参数

[`tool-parameters.json`](tool-parameters.json)：暴露给模型的 12 个工具的名字与参数 JSON Schema，顺序即发给模型的顺序。

- Vita API 的 Agent 从中读取（`api/src/agent/config.ts`，打包进 API 镜像）；2.0 起 iOS 不再打包它。
- Admin 试跑时用同一份，保证发给模型的工具定义和线上一致。
- 只随代码发布，远程配置不能改（Vita Admin 设计 §3.2）。工具的描述文字在 `ios/Vita/Resources/DefaultConfig.json`，远程配置可以替换。
- 契约见 [Agent 工具契约](../../docs/contracts/agent-tools.md)。
