# Vita

Vita 是一个本地优先的个人 AI 健康助理。当前 MVP 以自然语言记录饮食、营养追踪、目标管理和 Apple Health / HealthKit 集成为中心。

## 文档入口

| 文档 | 用途 | 状态 |
| --- | --- | --- |
| [PRD v0.6](docs/product/Vita-PRD-v0.6.md) | 已确认的产品需求来源 | 输入 |
| [技术设计文档](docs/architecture/TDD-v0.1.md) | 架构、数据、同步与安全设计 | 草案 |
| [架构决策记录](docs/architecture/ADR.md) | 已作出的暂定决策与待确认决策 | 草案 |
| [Agent 工具契约](docs/contracts/agent-tools.md) | Agent、客户端与写入确认边界 | 草案 |
| [模型 Provider 集成规范](docs/contracts/llm-provider.md) | Responses API、工具循环与密钥边界（直连方舟部分已被 Conduit 取代） | 已采纳，部分被取代 |
| [Vita Admin 设计](docs/architecture/vita-admin.md) | 远程配置、签名发布与诊断日志 | 草案 |
| [Conduit 项目设计](docs/architecture/llm-gateway-project.md) | 独立的 LLM 网关项目 | 草案 |
| [公共营养参考库规范](docs/reference-food-library.md) | 数据来源、收录规则、构建与校验 | 已采纳 |
| [MVP 实施计划](docs/implementation-plan.md) | 按依赖排序的开发阶段与验收点 | 草案 |

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

代码位于 `ios/Vita/`（App / Features / Domain / Data / Platform；`Application` 层随 Phase 1 加入），测试位于 `ios/VitaTests/`。当前进度：Phase 0、Phase 1 完成。Debug 构建加启动参数 `-VitaSeedSampleData` 可在今天写入样例数据，便于查看 Data 页。
