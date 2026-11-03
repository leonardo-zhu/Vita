# Agent 工具参数

[`tool-parameters.json`](tool-parameters.json)：暴露给模型的 12 个工具的名字与参数 JSON Schema，顺序即发给模型的顺序。

- iOS 把它打包进 App，`AgentToolCatalog` 从中读取（`ios/project.yml` 列为资源）；测试保证它和代码里的工具一一对应。
- Admin 试跑时用同一份，保证发给模型的工具定义和 App 一致。
- 只随客户端发布，远程配置不能改（Vita Admin 设计 §3.2）。工具的描述文字在 `ios/Vita/Resources/DefaultConfig.json`，远程配置可以替换。
- 契约见 [Agent 工具契约](../../docs/contracts/agent-tools.md)。
