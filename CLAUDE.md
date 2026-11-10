# Vita 项目约定

项目是什么、仓库结构、怎么跑见 [README.md](README.md)。

## 文档必须随改动一起更新

每次功能、修复、重构或配置改动，**在同一个提交里**检查并更新受影响的文档，不要留到以后。提交前自问：这次改动会让哪份文档说错或漏掉？

| 改了什么 | 更新哪里 |
| --- | --- |
| 新功能、行为变化、新表 / 新字段 / 新接口 / 新事件 | `docs/architecture/vita-2.0-architecture.md`：对应章节（§9 / §9a 健康、§10 Agent、§11 数据模型），并在 §16 加一条进度（日期、App 版本、一两句话） |
| 技术决策或决策的修订 | `docs/architecture/ADR.md`：新增 ADR，或在原条目里写“日期 补充：……” |
| Admin 页面、配置发布、设备令牌 | `docs/architecture/vita-admin.md`（顶部加一行带日期的变化说明，并改对应小节） |
| Agent 的 prompt、护栏、工具、评测、模型选择 | `docs/agent-tuning-log.md`：专题写结论，§10 时间线加一行，更新“最后更新”日期；prompt 变了还要加 §9 版本行；工具契约变了同步 `docs/contracts/agent-tools.md` |
| 体脂秤、身体成分算法 | `docs/product/Vita-Body-Composition.md` |
| 部署、环境变量、接入第三方服务的步骤 | `api/README.md` 或 `admin/README.md`（环境变量同时改 `.env.example`） |
| iOS 版本号（`ios/project.yml` 的 `MARKETING_VERSION`）、对外可见的现状 | `README.md` 的“当前技术基线”和文档入口表 |
| 产品层面的范围或规则变化 | `docs/product/Vita-PRD-v2.0.md`（2.0 之外沿用 PRD v0.6，不改 v0.6） |

### 规则

- 以现状为准的文档：README、PRD v2.0、2.0 架构设计、ADR、Agent 工具契约、Agent 调优记录。PRD v0.6、TDD、`implementation-plan.md` 是 1.0 的历史记录，正文不改。
- 写日期用绝对日期（如 2026-11-09），不要写“今天”“最近”。
- 接口或事件有兼容性约束（如可选事件只发给声明了的客户端）要写明原因，旧版 App 的行为尤其要写。
- 只改代码注释、测试或纯内部重构，且不影响上表任何一项时，可以不改文档；提交说明里不用特意写。
- 回复里汇报改动时，顺带说明更新了哪些文档；确认不需要更新时也说一句原因。
- 文档里的文件名、接口、表名改完后用 `grep` 确认没有残留旧名字。
