# Vita

Vita 是一个个人 AI 健康助理：用自然语言记录饮食，追踪营养与目标，结合 Apple 健康与体脂秤的数据。2.0 起数据与 Agent 都在自建的 Vita API 上，iPhone App 负责界面以及 Apple 健康、体脂秤、相机这些设备能力。

## 文档入口

按下面的顺序读：先建立全貌，再看决策与 Agent，专题按需看，1.0 的历史记录需要时再查。

**一、全貌**

| 文档 | 内容 | 状态 |
| --- | --- | --- |
| 本 README | 项目是什么、现状、仓库结构、怎么跑起来 | 当前 |
| [PRD v2.0](docs/product/Vita-PRD-v2.0.md) | 2.0 在产品上改了什么、为什么；没提到的规则沿用 PRD v0.6 | 已评审，M1–M5 已实现 |
| [Vita 2.0 架构设计](docs/architecture/vita-2.0-architecture.md) | 服务端、App 改造、Apple 健康同步、迁移、Google 健康（§9a）；§16 是 M1–M5 及之后的进度记录 | 已评审，M1–M5 已实现 |

**二、决策与 Agent**

| 文档 | 内容 | 状态 |
| --- | --- | --- |
| [架构决策记录](docs/architecture/ADR.md) | 每个关键技术决定与理由（ADR-019 起为 2.0）；先扫一遍，其他文档引用时再细看 | 已采纳 |
| [Agent 工具契约](docs/contracts/agent-tools.md) | 模型能调哪些工具、确认门怎么约束它 | 已实现 |
| [Agent 调优记录](docs/agent-tuning-log.md) | 为 Agent 做过的可靠性与速度优化、实验与模型对比数据、prompt 版本 | 持续更新 |

**三、专题（按需）**

| 文档 | 内容 | 状态 |
| --- | --- | --- |
| [Vita Admin 设计](docs/architecture/vita-admin.md) | 后台各页面、配置发布、Prompt 调试、对话与数据管理 | 已部署 |
| [身体成分模块](docs/product/Vita-Body-Composition.md) | 体脂秤、各项指标的算法与校准 | 已实现 |
| [api/README](api/README.md)、[admin/README](admin/README.md)、[tools/agent-eval/README](tools/agent-eval/README.md) | 各部分的开发、部署、评测怎么做 | 当前 |

**四、参考与历史（需要时查）**

| 文档 | 内容 | 状态 |
| --- | --- | --- |
| [模型 Provider 集成规范](docs/contracts/llm-provider.md) | Responses API、流式、工具循环与密钥边界；2.0 起调用方是 Vita API | 已实现，部分被取代 |
| [Conduit 项目设计](docs/architecture/llm-gateway-project.md) | 独立的 LLM 网关项目 | 已上线 |
| [公共营养参考库规范](docs/reference-food-library.md) | 数据来源、收录规则、构建与校验 | 已采纳 |
| [PRD v0.6](docs/product/Vita-PRD-v0.6.md) | 1.0 的产品需求，2.0 没改的规则沿用 | 1.0 基线 |
| [技术设计文档](docs/architecture/TDD-v0.1.md) | 1.0 的架构、数据、同步与安全设计；领域规则仍有效 | 1.0 基线 |
| [MVP 实施计划](docs/implementation-plan.md) | 1.0 的开发阶段记录（按当时写成，不再改）；末尾“剩余工作”按现状维护 | 1.0 完成 |

PRD v0.6、TDD、实施计划的正文与现状不一致是正常的；以现状为准的是本 README、PRD v2.0、2.0 架构设计、ADR、Agent 工具契约与 Agent 调优记录。

## 当前技术基线

- iOS 原生应用：Swift、SwiftUI、HealthKit；最低部署版本为 iOS 17，当前版本 2.5.1。业务数据不存手机，只存设备令牌（Keychain）、Apple 健康的同步进度与没传上去的称重；不拉配置、不上报诊断日志。
- Vita API（`api/`）：Node 24 + TypeScript + Hono + `node:sqlite`，部署在 R4S（`https://vita-api.r4s.leonardo-zhu.me`）。记录、食品库、目标、对话、确认卡、称重、标签照片都以它为准；Agent 的工具循环与确认门也在这里跑，经 Conduit 调模型，模型密钥只在服务端。活动能量与睡眠由服务端从 Google 健康拉取（Apple 健康里没有这两项）；随活动计算的能量目标每天按最新体重重算基础代谢，变化会记录下来。
- Vita Admin（`admin/`，`https://vita.r4s.leonardo-zhu.me/admin`）：发布模型参数与 prompt（Vita API 每轮读取）、Prompt 调试、设备令牌、Google 健康授权、目标变更（基础代谢与目标历史，只读）；对话追踪与 rewind、饮食记录、食品库（含营养值版本）的管理经 API。诊断页只剩 1.0 时期的历史数据。
- 模型经 Conduit（`https://conduit.r4s.leonardo-zhu.me`）调用，当前别名 `vita-chat` → `doubao-seed-2.1-lite`（2026-11-11 核实，此前是 `ark-code-latest`）。确认门不变：模型只能查询和提出变更，用户在 App 里确认后才写入（ADR-004）；用户在 App 或 Admin 里直接改数据不经确认卡。
- 请求 / 响应定义在 `packages/contract`（zod），API 与 Admin 共用；iOS 按它手写 Swift 模型。

中国食物成分数据仅用于你的私有本地构建；若未来公开分发，须重新核验授权。

## 开发

仓库按子系统分目录：`ios/`（iOS App）、`api/`（Vita API）、`admin/`（Vita Admin）、`packages/contract/`（API 的接口定义）、`shared/`（跨端共用的文件：内置配置与 prompt `shared/config/DefaultConfig.json`、工具参数、schema、样例）、`tools/`（公共参考库构建 `reference-food/`、Agent 评测 `agent-eval/`）、`docs/`。根目录是 pnpm workspace，`pnpm install` 一次即可。API 与 Admin 推到 `main` 后由 GitHub Actions 自动部署到 R4S，见 [api/README.md](api/README.md)、[admin/README.md](admin/README.md)。

iOS 工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 根据 `ios/project.yml` 生成，`ios/Vita.xcodeproj` 不提交。

```bash
brew install xcodegen   # 首次
cd ios
xcodegen generate
xcodebuild test -project Vita.xcodeproj -scheme Vita -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.4'
```

装到连着的 iPhone：`sh ios/scripts/install-iphone.sh`（免费开发者证书签的包 7 天后过期，过期后重跑即可，数据不会丢）。

代码位于 `ios/Vita/`（App / Application / Domain / Data / Features / Platform），测试位于 `ios/VitaTests/`。当前进度：1.0 的 Phase 0–5 完成；2.0 的 M1–M5 已实现，见[架构设计 §16](docs/architecture/vita-2.0-architecture.md#16-分期)；剩余工作见[实施计划](docs/implementation-plan.md#剩余工作)。

### 版本号

规则见 [ADR-023](docs/architecture/ADR.md)，简单说：

- **App**：`ios/project.yml` 的 `MARKETING_VERSION`。产品代际变了动主版本；完成一个里程碑或一批新功能，次版本 +1、修订归零；只修 bug 修订 +1。和那批改动放在同一个提交里，装手机前改好。构建号和提交哈希自动写入，不用管。
- **API、Admin**：不设版本号，看提交哈希（`/v1/health` 返回的 `version`、镜像标签）。
- **接口**：`/v1` 只加不删，手机上的旧版本要能继续用；必须破坏时开 `/v2`。

### 运行

1. App 的数据都在 Vita API（地址由 `ios/project.yml` 的 `VITA_API_BASE_URL` 决定），模型经 API 调 Conduit，手机上没有模型密钥。
2. 在 Vita Admin 的“设备”页给手机签发设备令牌，首次打开 App 时粘贴进去（只存本机钥匙串）。手机上还有 1.0 的数据时，接着会进入迁移页（架构设计 §13）。
3. 本地调试：按 [api/README.md](api/README.md) 在本机起 API（参考库指向 `ios/Resources/ReferenceFood/reference-foods.json`）；构建时加 `VITA_API_BASE_URL=http://127.0.0.1:3014`（只有 Debug 构建允许连本机 HTTP），再用服务令牌调 `POST /v1/admin/devices` 签发令牌。不要让模拟器连正式服务：模拟器读到的空健康数据会覆盖服务端存的身体数据。
4. iOS 27.1 模拟器的 `healthd` 不响应 HealthKit 的同步授权查询，App 会卡在读健康数据处（1.0 同样如此）；在模拟器上调试、跑测试请用 iOS 18.4 运行时，或用真机。
5. 改了 prompt 或想换模型：先跑 `tools/agent-eval/run.mjs` 的固定用例对比（用测试专用的 Conduit key，见 [tools/agent-eval/README.md](tools/agent-eval/README.md)），结果记进 [Agent 调优记录](docs/agent-tuning-log.md)。

### 模拟器提示

- 往模拟器粘贴中文时，若剪贴板经 `xcrun simctl pbcopy`，需加 `LC_ALL=en_US.UTF-8`，否则会变成乱码；或在模拟器里按 ⌘K 调出软键盘直接输入。
- App 日志（健康同步、迁移、称重）：`xcrun simctl spawn booted log stream --level info --predicate 'subsystem == "com.leonardo.vita"'`。Agent 的工具调用在服务端，看 Admin 的对话追踪或 API 的容器日志。
