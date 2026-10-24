# Vita

Vita 是一个本地优先的个人 AI 健康助理。当前 MVP 以自然语言记录饮食、营养追踪、目标管理和 Apple Health / HealthKit 集成为中心。

项目尚未进入编码阶段；仓库当前保存产品与技术基线，供后续评审和实现使用。

## 文档入口

| 文档 | 用途 | 状态 |
| --- | --- | --- |
| [PRD v0.6](docs/product/Vita-PRD-v0.6.md) | 已确认的产品需求来源 | 输入 |
| [技术设计文档](docs/architecture/TDD-v0.1.md) | 架构、数据、同步与安全设计 | 草案 |
| [架构决策记录](docs/architecture/ADR.md) | 已作出的暂定决策与待确认决策 | 草案 |
| [Agent 工具契约](docs/contracts/agent-tools.md) | Agent、客户端与写入确认边界 | 草案 |
| [模型 Provider 集成规范](docs/contracts/llm-provider.md) | 火山方舟 Responses API、工具循环与密钥边界 | 已采纳 |
| [公共营养参考库规范](docs/reference-food-library.md) | 数据来源、收录规则、构建与校验 | 已采纳 |
| [MVP 实施计划](docs/implementation-plan.md) | 按依赖排序的开发阶段与验收点 | 草案 |

## 当前技术基线

- iOS 原生应用：Swift、SwiftUI、SwiftData、HealthKit；最低部署版本为 iOS 17。
- 单人、本地优先；业务数据不需要账户、服务端或云同步。
- Agent 首先通过火山方舟的 OpenAI 兼容 Responses API 访问；`LLMClient` 保持可替换，模型只可读取和提出变更，正式写入由客户端在用户确认后执行。
- 用户 Nutrition DB、记录、目标、Pending 和同步映射均为本地数据；公共参考库为只读内置资源。

公共营养库、iOS 最低版本、时间策略与首个模型接入均已定稿。中国食物成分数据仅用于你的私有本地构建；若未来公开分发，须重新核验授权。
