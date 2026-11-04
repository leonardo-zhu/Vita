# 远程配置 Schema

远程配置 `config.json` 的 JSON Schema 与测试用例，由 `admin/`（发布前校验）和 `ios/`（拉取后校验的测试夹具）共用。2.0 起真正使用配置的是 Vita API（每轮对话读 Admin 发布的 `stable.json`）；iOS 仍会拉取并校验，但结果已经没有地方用，见《Vita 2.0 架构设计》§10.2。

字段与校验规则见 [Vita Admin 设计](../../docs/architecture/vita-admin.md) §4 / §6。

- [`config.schema.json`](config.schema.json)：结构与取值范围。`configVersion` 单调递增、`minClientVersion` 的比较依赖运行时状态，由客户端与 Admin 各自在代码里检查。
- 内置默认值 `shared/config/DefaultConfig.json` 也符合此 schema（L1 层，字段齐全，包括全部工具的描述）。Admin 从它读工具清单与默认文字，Vita API 把它当作内置默认值（打包进镜像）。2.0 起 App 不再读配置。
- `configVersion` 的序号按数字比较（`.10` 大于 `.9`），Admin（`version.ts`）与 iOS（`ConfigVersion`）实现相同。
