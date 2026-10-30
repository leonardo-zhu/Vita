# Vita Agent 工具契约（草案）

## 目标

将“理解自然语言”与“改变本地数据”严格分开。模型负责结构化理解、查询与建议；客户端负责校验、Pending 生命周期、事务写入和 HealthKit 同步。

模型的每次工具调用必须携带 `sessionDate`（`YYYY-MM-DD`）和 `requestId`。客户端从当前界面状态注入 `sessionDate`，而不是信任模型自行推断的日期。

## 权限级别

| 级别 | 工具 | 行为 |
| --- | --- | --- |
| Read | `getDaySummary`、`getRecordDetail`、`searchPersonalFoods`、`searchReferenceFoods`、`getGoals`、`getHealthSnapshot`、`getGoalRecommendation` | 仅读取或由客户端计算预览；历史日期可读。`getGoalRecommendation` 不写入任何数据。 |
| Propose | `proposeRecordChange`、`proposeFoodChange`、`proposeRecordDeletion` | 校验输入后创建或替换该日期唯一的 Pending；不写正式业务数据。 |
| Direct command | `updateGoal` | 仅在用户指令明确、参数完整时直接执行；否则模型先在对话中取得确认，不创建 Pending。 |
| Client-only commit | `confirmPending`、`cancelPending`、`expirePending`、`runHealthSync`、`commitInitialGoals`、`submitManualBodyMetrics`、`attachNutritionLabel` | 不暴露给模型。由卡片交互、表单、系统选择器、时钟或应用服务调用。 |

## 公共信封

```json
{
  "requestId": "uuid",
  "sessionDate": "2026-09-17",
  "expectedRevision": 12,
  "payload": {}
}
```

- `expectedRevision` 是该 Session 数据快照版本；提交时不匹配则拒绝，并要求重新生成提案。
- 所有 ID 使用客户端生成的 UUID。模型可引用已返回的 ID，但不可构造一个 ID 来越权访问其他日期。
- 查询结果只返回完成任务所需字段；图片、原始提示词和 Keychain 信息永不发送给工具结果。

## 关键工具

### `searchPersonalFoods`

输入：自然语言 `query`。输出：个人 Food Product 的小型结构化列表，含当前有效 Version、包装规格和营养基准。个人库规模小，可将列表摘要随会话上下文提供；本工具用于取得精确 ID。

### `searchReferenceFoods`

输入：`query` 和可选 `aliases`。输出：精确名称或别名命中的参考条目。若结果不唯一，模型必须发起澄清；不得从多个候选中猜测“生/熟”等实质属性。

### `proposeRecordChange`

输入包含意图（`create` / `appendItems` / `replaceItem` / `removeItem`）、目标 Record ID（非创建时必填）和完整的候选 Record 快照。每个 Item 必须包含：

- 用户原始用量表达、标准化 `g` 或 `ml`、`amountSource`；
- `nutritionSource`（personal / reference / aiEstimate）及其来源引用：
  - personal / reference：模型只提交 Food Version ID 或参考条目 ID 加标准化用量，**不提交营养数值**。客户端按「每基准值 × 用量」自行计算营养快照，并记录计算依据（见 TDD §3.2 `nutritionSnapshot`）。
  - aiEstimate：模型提交营养数值，并必须附 `estimateBasis`（一句话说明估算依据，如假设的单个重量、参照的常见值）；客户端存入快照并标记为估算，卡片上显式展示。
- 是否纳入汇总、可选 Group、可选 Meal Label；
- 事件时间值和精度，而非伪造的精确时间。

客户端再次校验：Session 日期一致、目标记录属于当前 Session、标准化单位有效、营养值非负、引用的 Food Version/参考条目存在。校验成功后覆盖该日期既有 Pending，生成确认卡；失败则返回可面向模型解释的错误。

当用户完全未表达事件时间时，客户端（不是模型）注入“Session 日期 + 当前本地时分秒”，并标记 `defaultedEntryTime`。用户明确表达餐段、模糊时间或仅日期时，不得以当前时间覆盖。

#### 参数格式（Phase 2 定稿）

`proposeRecordChange` 的 `payload`：

```json
{
  "intent": "create",
  "recordId": "uuid（非 create 时必填）",
  "itemId": "uuid（replaceItem / removeItem 必填）",
  "record": {
    "eventTime": { "precision": "mealPeriod", "mealPeriod": "lunch" },
    "mealLabel": "午餐",
    "items": [
      {
        "displayName": "鸡蛋",
        "originalAmountText": "2 个鸡蛋、共 108g",
        "quantity": { "amount": 108, "unit": "g" },
        "amountSource": "userMeasured",
        "nutrition": { "source": "referenceFood", "referenceFoodId": "vita.reference.egg.whole.raw" },
        "includeInSummary": true
      }
    ]
  },
  "items": ["appendItems 用"],
  "item": "replaceItem 用",
  "replacesPendingId": "修正当前 Pending 时填"
}
```

- `eventTime` 省略表示用户没表达时间，由客户端注入 `defaultedEntryTime`；模型不能自己声明该精度。`exact` / `approximate` 用 `time: "HH:mm"`，日期与时区取当前 Session。
- `quantity.unit` 可用 g / kg / mg / 斤 / 两 / ml / L 及中文写法，由客户端标准化为 g / ml；计数单位（个、碗）须由模型换算或省略用量走估算。
- `nutrition.source` 为 `referenceFood` / `personalFoodVersion` 时只看 ID，附带的 `values` 一律忽略；`aiEstimated` 必须带 `values` 与 `estimateBasis`。
- `proposeRecordDeletion` 的 `payload` 为 `{ "recordId", "replacesPendingId"? }`。
- 结果为 `{ ok, pendingId?, requestedDate?, error?: { code, message } }`。错误码：`requiresDateSwitch`、`pendingActive`、`pendingNotFound`、`revisionConflict`、`recordNotFound`、`itemNotFound`、`emptyRecord`、`invalidItem`、`missingField`、`invalidField`、`malformedArguments`、`unknownTool`。

### `proposeFoodChange`

输入为 Food Product 与不可变 Food Version 草稿，并包含标签图片本地引用（如有）及其解析置信信息。创建 Product 或 Version 都需要 Pending 确认。AI 纯估算项目不得作为输入来源创建 Food Version。

#### 参数格式（Phase 3 定稿）

```json
{
  "intent": "createProduct",
  "productId": "uuid（addVersion 必填）",
  "expectedActiveVersionId": "uuid（addVersion：模型看到的生效版本）",
  "product": { "name": "某品牌纯牛奶", "brandOrSupplier": "某乳业", "package": { "amount": 250, "unit": "ml" }, "note": null },
  "version": {
    "source": "nutritionLabel",
    "labelScanId": "uuid（nutritionLabel 必填，来自 attachNutritionLabel）",
    "referenceFoodId": "referenceDerived 必填",
    "basis": { "amount": 100, "unit": "ml" },
    "values": { "energyKcal": 65, "proteinG": 3.2, "fatG": 3.6, "carbohydrateG": 4.8 },
    "note": "可选"
  },
  "replacesPendingId": "修正当前 Pending 时填"
}
```

- `source` 只接受 `nutritionLabel` / `manualEntry` / `referenceDerived`，其他（包括 `aiEstimated`）返回 `estimateNotAllowed`。
- `referenceDerived` 的基准与营养值由客户端从参考库复制，模型给的忽略。
- `nutritionLabel` 的 `values` 由模型根据识别候选给出（可修正识别错误），图片引用由客户端按 `labelScanId` 查得，模型拿不到也不能伪造本地路径。
- 提案后产品的生效版本已变化时，确认会失败并作废（`revisionConflict`）。
- 新增错误码：`estimateNotAllowed`、`productNotFound`、`unknownLabel`、`invalidFood`。

### `updateGoal`

输入为一个或多个明确数值目标、单位和用户命令证据。客户端仅接受完整明确指令；建议性语言应由模型在聊天中澄清后再调用。成功后递增 Goal revision 并记录审计日志。

结果必须返回**旧值与新值**，模型据此复述。没有专门的撤销机制：用户想反悔时，以明确指令（如“改回 160g”）再次调用 `updateGoal` 即可；旧值可由 `getGoals` 的 revision 历史取得。

### `getGoalRecommendation`

只读。客户端用 `GoalRecommendationPolicy`（TDD §6.2）基于 HealthKit 读数与手动补录数据计算，返回输入项（含来源：HealthKit / 手动 / 估算）、公式、结果与缺失项。体重缺失时返回“无法生成”。**模型不自行计算目标数值。**

首次生成目标属于“一次性确认”，不走 Pending：模型展示预览，用户在目标预览卡上点击确认后由客户端调用 `commitInitialGoals` 写入（`origin = initialRecommendation`）。

### 手动身体数据与标签图片（client-only 入口）

- `submitManualBodyMetrics`：体重、身高、体脂率、出生日期、生理性别缺失时，由 Onboarding 或设置页表单提交。仅用于目标生成，保存在目标的 evidence snapshot 中，**不写回 HealthKit**。`getHealthSnapshot` 与 `getGoalRecommendation` 返回时标注数据来源。
- `attachNutritionLabel`：用户通过相册或相机选择营养标签图片，客户端本地存储并先做本地 OCR；只把 OCR 得到的结构化文本候选与置信信息交给模型，**原图默认不发送**（TDD §8）。模型据此调用 `proposeFoodChange`，仍需 Pending 确认。

## Pending 状态机

```text
none → readyForConfirmation → confirmed
              ├──────────────→ cancelled
              └──────────────→ expired
```

- 澄清（生熟、多候选、用量缺失）发生在聊天中，**不创建 Pending**；只有通过校验、可直接确认的提案才创建 Pending。
- 每个 `sessionDate` 最多一个 `readyForConfirmation` Pending。
- `confirmed` 才会在一个本地事务中修改正式数据，并安排 HealthKit outbox 操作。
- 新的独立写入在 Pending 活跃时被拒绝；查询、澄清、修正和取消被允许。修正会替换 Pending 内容。
- `expiresAt = min(createdAt + 30 分钟, createdAt 所在本地自然日的次日 00:00)`。截止点取决于**创建 Pending 的真实时间**，而不是 `sessionDate`：向历史日期写入时，用 `sessionDate` 次日 00:00 会使 Pending 创建即过期。打开 App、切换日期、进入前台和提交前都必须清理过期项。

## 模型输出要求

模型回复应把“事实”“估算”“需要确认”清楚分开。出现多个营养匹配、会明显改变营养的生熟差异或用量缺失时，优先询问，不得生成看似确定的 Pending。
