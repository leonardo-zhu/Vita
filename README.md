# Vita

Vita 是一个个人 AI 健康助理：用自然语言记录饮食，追踪营养与目标，结合 Apple 健康与体脂秤的数据。2.0 起数据与 Agent 都在自建的 Vita API 上，iPhone App 负责界面以及 Apple 健康、体脂秤、相机这些设备能力。

## 文档入口

| 文档 | 用途 | 状态 |
| --- | --- | --- |
| [PRD v2.0](docs/product/Vita-PRD-v2.0.md) | 2.0 相对 1.0 的产品变化 | 已评审，M1–M3 已实现 |
| [Vita 2.0 架构设计](docs/architecture/vita-2.0-architecture.md) | 服务端、iOS 改造、Apple 健康同步、迁移，以及 2.0 的进度 | 已评审，M1–M3 已实现 |
| [PRD v0.6](docs/product/Vita-PRD-v0.6.md) | 1.0 的产品需求，2.0 没改的规则沿用 | 基线 |
| [身体成分模块](docs/product/Vita-Body-Composition.md) | 体脂秤、指标、校准 | 已实现 |
| [技术设计文档](docs/architecture/TDD-v0.1.md) | 1.0 的架构、数据、同步与安全设计；领域规则仍有效 | 1.0 基线 |
| [架构决策记录](docs/architecture/ADR.md) | 已作出的技术决策（ADR-019 起为 2.0） | 已采纳 |
| [Agent 工具契约](docs/contracts/agent-tools.md) | Agent 工具与写入确认边界；2.0 起在服务端执行 | 已实现 |
| [模型 Provider 集成规范](docs/contracts/llm-provider.md) | Responses API、工具循环与密钥边界；2.0 起调用方是 Vita API | 已实现，部分被取代 |
| [Vita Admin 设计](docs/architecture/vita-admin.md) | 远程配置发布、Prompt 调试、诊断日志、设备令牌 | M1–M3 已部署 |
| [Conduit 项目设计](docs/architecture/llm-gateway-project.md) | 独立的 LLM 网关项目 | 已上线 |
| [公共营养参考库规范](docs/reference-food-library.md) | 数据来源、收录规则、构建与校验 | 已采纳 |
| [MVP 实施计划](docs/implementation-plan.md) | 1.0 的开发阶段记录与剩余工作 | 1.0 完成，剩余工作按 2.0 更新 |

## 当前技术基线

- iOS 原生应用：Swift、SwiftUI、HealthKit；最低部署版本为 iOS 17。业务数据不存手机，只存设备令牌（Keychain）、Apple 健康的同步进度与没传上去的称重。
- Vita API（`api/`）：Node 24 + TypeScript + Hono + `node:sqlite`，部署在 R4S（`https://vita-api.r4s.leonardo-zhu.me`）。记录、食品库、目标、对话、确认卡、称重、标签照片都以它为准；Agent 的工具循环与确认门也在这里跑，经 Conduit 调模型，模型密钥只在服务端。
- Vita Admin（`admin/`）：远程配置发布、Prompt 调试、诊断日志、设备令牌管理；数据管理经 API。
- 确认门不变：模型只能查询和提出变更，用户在 App 里确认后才写入（ADR-004）。
- 请求 / 响应定义在 `packages/contract`（zod），API 与 Admin 共用；iOS 按它手写 Swift 模型。

中国食物成分数据仅用于你的私有本地构建；若未来公开分发，须重新核验授权。

## 开发

仓库按子系统分目录：`ios/`（iOS App）、`api/`（Vita API）、`admin/`（Vita Admin）、`packages/contract/`（API 的接口定义）、`shared/`（跨端共用的 schema 与样例）、`docs/`。根目录是 pnpm workspace，`pnpm install` 一次即可；API 的开发与部署见 [api/README.md](api/README.md)。

iOS 工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 根据 `ios/project.yml` 生成，`ios/Vita.xcodeproj` 不提交。

```bash
brew install xcodegen   # 首次
cd ios
xcodegen generate
xcodebuild test -project Vita.xcodeproj -scheme Vita -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

代码位于 `ios/Vita/`（App / Application / Domain / Data / Features / Platform），测试位于 `ios/VitaTests/`。当前进度：1.0 的 Phase 0–5 完成；2.0 的 M1–M3 已实现，见[架构设计 §16](docs/architecture/vita-2.0-architecture.md#16-分期)；剩余工作见[实施计划](docs/implementation-plan.md#剩余工作)。

### 运行

1. App 的数据都在 Vita API（地址由 `ios/project.yml` 的 `VITA_API_BASE_URL` 决定），模型经 API 调 Conduit，手机上没有模型密钥。
2. 在 Vita Admin 的“设备”页给手机签发设备令牌，首次打开 App 时粘贴进去（只存本机钥匙串）。手机上还有 1.0 的数据时，接着会进入迁移页（架构设计 §13）。
3. 本地调试：按 [api/README.md](api/README.md) 在本机起 API（参考库指向 `ios/Resources/ReferenceFood/reference-foods.json`）；构建时加 `VITA_API_BASE_URL=http://127.0.0.1:3014`（只有 Debug 构建允许连本机 HTTP），再用服务令牌调 `POST /v1/admin/devices` 签发令牌。不要让模拟器连正式服务：模拟器读到的空健康数据会覆盖服务端存的身体数据。
4. iOS 27.1 模拟器的 `healthd` 不响应 HealthKit 的同步授权查询，App 会卡在读健康数据处（1.0 同样如此）；在模拟器上调试请用 iOS 18.4 运行时，或用真机。

### 模拟器提示

- 往模拟器粘贴中文时，若剪贴板经 `xcrun simctl pbcopy`，需加 `LC_ALL=en_US.UTF-8`，否则会变成乱码；或在模拟器里按 ⌘K 调出软键盘直接输入。
- App 日志（健康同步、迁移、称重）：`xcrun simctl spawn booted log stream --level info --predicate 'subsystem == "com.leonardo.vita"'`。Agent 的工具调用在服务端，看 Admin 的对话追踪或 API 的容器日志。
