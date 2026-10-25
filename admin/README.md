# Vita Admin

Next.js 管理后台：远程配置的编辑、校验、签名发布，以及客户端诊断日志的接收与查看。

设计见 [Vita Admin 设计](../docs/architecture/vita-admin.md)。尚未开始实现（M1 起）。

约定：

- 包管理器使用 pnpm。
- 配置校验使用 `../shared/config-schema/` 中的 JSON Schema，与 iOS 端共用。
- 模型网关不在此处，见独立项目 Conduit。
