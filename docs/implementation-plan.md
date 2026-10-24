# Vita MVP 实施计划（草案）

每个阶段都应有可手工验收的最小闭环；不以“接上模型”为由跳过本地数据正确性与同步测试。

## Phase 0：项目基础

- 创建最低部署版本为 iOS 17 的 SwiftUI 工程，配置 SwiftLint（可选）与 XCTest。
- 建立 Feature / Domain / Data / Platform 分层，初始化 SwiftData container、Keychain 和依赖注入。
- 加入文档中定义的领域值类型和迁移策略。

验收：冷启动可创建空数据库；单元测试可使用内存 store。

## Phase 1：本地领域与 Data

- 实现 Session、ChatMessage、Record、Item、Food Product / Version、Goal 与公共参考库读取。
- 加入一份**测试用小型参考库 fixture**（十余条，含生/熟鸡胸肉等多候选情形，不含任何中国来源真实数据），使本阶段与 Phase 2 不依赖 Phase 3 的正式构建。
- 实现营养计算、日汇总、日期导航和只读 Data 页面。
- 实现时间精度、单位标准化与 Revision 校验。

验收：不依赖模型即可通过 fixture 创建、修改、删除记录；当天总营养和目标完成度正确更新。

## Phase 2：确认式记录流程

- 实现 PendingStore、确认卡片、取消、替换、TTL 与跨天清理。
- 以假 Agent（fixture JSON）驱动所有 create / append / replace / delete 分支。
- 写入审计日志，验证过期 Pending 不产生正式数据。

验收：同一日期只能有一个活跃 Pending；重启后未过期 Pending 可恢复；跨午夜/30 分钟后自动取消。

## Phase 3：Nutrition DB 与标签录入

- 实现 Food Product、不可变 Food Version、包装规格和引用快照。
- 加入本地图片存储与 OCR/解析适配接口，所有解析结果走确认卡。
- 按《公共营养参考库规范》构建首批公共营养 JSON、中文别名与精确查询：中国来源数据（用户本地私有输入，Git 忽略）优先，USDA FoodData Central 补充中国库未覆盖的食材。
- 实现 `attachNutritionLabel`：本地 OCR 后只把结构化候选交给模型，原图不外发。

验收：历史 Item 的营养结果不随 Food Version 更新而改变；AI 估算不能被直接保存为个人食品版本。

## Phase 4：HealthKit 与目标

- 实现读权限、缺失数据兜底（含 `submitManualBodyMetrics`）、`getGoalRecommendation` 预览 + `commitInitialGoals` 一次性确认，以及 `updateGoal` 明确指令更新（保留旧行，可用指令改回）。
- 实现 HealthKit outbox、UUID mapping、修改替换、删除撤销和权限撤销提示。
- 在模拟 HealthKit adapter 中覆盖失败与重试情形。

验收：同一 Record 多次修改后 HealthKit 只有最新版 Sample；无写入权限时本地记录仍正确且显示待解决同步状态。

## Phase 5：Agent 接入与体验打磨

- 以 `LLMClient` 接入选定 Provider，启用结构化输出/工具调用。
- 为工具参数、模型输出、超时和网络错误增加校验与可恢复提示。
- 实现 Chat / Data 双层导航、按日 Session、Onboarding。

验收：使用真实对话完成“记录、确认、查看、修正、删除”全链路，且所有写入均通过确认门。

## 必须覆盖的测试场景

1. 生/熟鸡胸肉同时命中时必须澄清，不能选一个写入。
2. “2 个鸡蛋、共 108g”以 108g 计算并保留原始表达。
3. “昨天吃了…”在今天 Session 中只提出切换，不写昨天数据。
4. 修改或删除已同步 Record 时，先删除旧 HK Sample 再写新 Sample / 清映射。
5. Pending 过期、切换到次日、App 重启与 Revision 冲突均不产生幽灵写入。
6. 个人 Food Version 更新后，旧 Consumption Item 保持原营养快照。
7. 在历史日期 Session 中创建的 Pending，`expiresAt` 为创建后 30 分钟（或当天午夜，取较早者），不会创建即过期。
