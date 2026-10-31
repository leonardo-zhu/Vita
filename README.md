# Vita

Vita 是一个本地优先的个人 AI 健康助理。当前 MVP 以自然语言记录饮食、营养追踪、目标管理和 Apple Health / HealthKit 集成为中心。

## 文档入口

| 文档 | 用途 | 状态 |
| --- | --- | --- |
| [PRD v0.6](docs/product/Vita-PRD-v0.6.md) | 已确认的产品需求来源 | 输入 |
| [技术设计文档](docs/architecture/TDD-v0.1.md) | 架构、数据、同步与安全设计 | 草案 |
| [架构决策记录](docs/architecture/ADR.md) | 已作出的暂定决策与待确认决策 | 草案 |
| [Agent 工具契约](docs/contracts/agent-tools.md) | Agent、客户端与写入确认边界 | 已实现 |
| [模型 Provider 集成规范](docs/contracts/llm-provider.md) | Responses API、工具循环与密钥边界（直连方舟部分已被 Conduit 取代） | 已实现，部分被取代 |
| [Vita Admin 设计](docs/architecture/vita-admin.md) | 远程配置、签名发布与诊断日志 | 草案 |
| [Conduit 项目设计](docs/architecture/llm-gateway-project.md) | 独立的 LLM 网关项目 | 草案 |
| [公共营养参考库规范](docs/reference-food-library.md) | 数据来源、收录规则、构建与校验 | 已采纳 |
| [MVP 实施计划](docs/implementation-plan.md) | 开发阶段、各阶段状态与剩余工作 | 进行中 |

## 当前技术基线

- iOS 原生应用：Swift、SwiftUI、SwiftData、HealthKit；最低部署版本为 iOS 17。
- 本地优先；业务数据不需要账户、云同步，也不进入任何服务端。
- 配套服务：Vita Admin（远程配置与诊断日志，位于 `admin/`）；模型调用统一经独立项目 Conduit（LLM 网关）。客户端不持有上游模型 Key。
- Agent 通过 Conduit 的 Responses API 访问模型；`LLMClient` 保持可替换，模型只可读取和提出变更，正式写入由客户端在用户确认后执行。
- 用户 Nutrition DB、记录、目标、Pending 和同步映射均为本地数据；公共参考库为只读内置资源。

公共营养库、iOS 最低版本、时间策略与首个模型接入均已定稿。中国食物成分数据仅用于你的私有本地构建；若未来公开分发，须重新核验授权。

## 开发

仓库按子系统分目录：`ios/`（iOS App）、`admin/`（Vita Admin）、`shared/`（跨端共用的 schema）、`docs/`。

iOS 工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 根据 `ios/project.yml` 生成，`ios/Vita.xcodeproj` 不提交。

```bash
brew install xcodegen   # 首次
cd ios
xcodegen generate
xcodebuild test -project Vita.xcodeproj -scheme Vita -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

代码位于 `ios/Vita/`（App / Application / Domain / Data / Features / Platform），测试位于 `ios/VitaTests/`。当前进度：Phase 0–5 完成，远程配置待定；剩余工作见[实施计划](docs/implementation-plan.md#剩余工作)。

### 运行

1. 在 Conduit 的应用 Vita 下配好模型别名 `vita-chat`（需支持工具调用）并生成一把密钥。Conduit 地址由 `ios/project.yml` 的 `CONDUIT_BASE_URL` 决定。
2. 首次打开 App 走完引导后，在 Chat 页左上角“设置”里填写访问令牌（只存本机钥匙串）。
3. Debug 构建加启动参数 `-VitaSeedSampleData` 可在今天写入样例数据，便于查看 Data 页（不要在真机上用：它会把样例记录同步进 Apple 健康）。
4. 设置页连点版本号五次可打开调试覆盖（临时换模型别名、超时或系统 prompt）。

### 模拟器提示

- 往模拟器粘贴中文时，若剪贴板经 `xcrun simctl pbcopy`，需加 `LC_ALL=en_US.UTF-8`，否则会变成乱码；或在模拟器里按 ⌘K 调出软键盘直接输入。
- Agent 工具调用的诊断日志：`xcrun simctl spawn booted log stream --level info --predicate 'subsystem == "com.leonardo.vita"'`。
