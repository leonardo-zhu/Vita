# 远程配置 Schema

远程配置 `config.json` 的 JSON Schema 与测试用例，由 `admin/`（发布前校验）和 `ios/`（拉取后校验的测试夹具）共用。

字段与校验规则见 [Vita Admin 设计](../../docs/architecture/vita-admin.md) §4 / §6。

- [`config.schema.json`](config.schema.json)：结构与取值范围。`configVersion` 单调递增、`minClientVersion` 的比较依赖运行时状态，由客户端与 Admin 各自在代码里检查。
- iOS 的内置默认值 `ios/Vita/Resources/DefaultConfig.json` 也符合此 schema（L1 层，字段齐全）。
