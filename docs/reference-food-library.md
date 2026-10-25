# Vita 公共营养参考库规范

**状态：已采纳**  
**对应决策：** ADR-006  
**范围：** MVP 内置的通用食材营养参考值，不包含品牌食品或用户自行维护的 Food Product。

## 1. 决策

产品概念中的“公共”指通用、非品牌的参考食材，不代表所有上游数据都是开放数据。Vita 面向中国日常饮食，必须优先使用能反映中国食材品种、生产环境与本地食品形态的数据；不能因为 USDA 数据易于分发，就把美国参考值当作中国食材的唯一默认值。

数据源优先级如下：

1. **中国食物成分数据**：用户本人私有提供的《中国食物成分表》（中国疾控中心营养与健康所体系）衍生数据；对中国日常通用食材为第一选择，仅限本项目的本地个人构建；
2. **USDA FoodData Central**：当中国库没有合适条目时的通用/国际食材补充；其数据为 CC0/public domain，可合法筛选并随 App 离线内置；
3. **AI estimate**：两者均无法可靠匹配时，仅用于当前 Consumption Item。

国家卫生健康委员会在预包装食品营养标签问答中首先列出《中国食物成分表》，并说明该表未覆盖时可参考 USDA 等其他国家权威数据库。这与上述优先级一致。

### 1.1 私有使用边界

中国食物成分数据中心目前要求登录访问；FAO 对 2019 年《中国食物成分表》第 6 版第 2 册的记录标为 print-only。该信息不足以证明可以把整库数据复制到 Git 仓库或 App bundle。

Vita 当前是用户本人使用的非公开 App。按此项目边界，中国来源数据可以作为用户本人提供的本地构建输入；但此决定不声称原始数据具有开放许可证，也不扩大到公开使用。

- 中国来源原始文件、转换结果和生成的 `reference-foods.json` 必须加入 `.gitignore`，不提交到 Git；
- 不把它们上传到公开仓库、网盘、TestFlight、App Store 或交付给他人设备；
- 不以它们训练、微调或上传到第三方模型服务；
- 若项目将来转为公开发布、多人使用或服务端同步，必须暂停使用该数据并重新取得适当授权。

中国数据作为本地私有资源被审阅后编译进你的个人 App；它不是运行时从互联网抓取的数据源。

### 1.2 已评估但不可直接采用的仓库

`Sanotsu/china-food-composition-data` 是一份很有价值的转换与校对参考：它从《中国食物成分表标准版（第 6 版）》截图构建了约 1,677 条 JSON，也公开了识别、校验与人工修正过程。但它不是 Vita 的可直接导入源：仓库未提供可复用许可证，README 明确写明原书版权归原作者且脚本仅用于个人学习研究。

在本项目的私有个人使用范围内，可以将该仓库的**矫正版 JSON**作为本地转换输入；但不能克隆进 Vita 仓库、提交其 JSON/CSV/XLSX/截图或其派生数据，也不能把包含这些数据的构建物交付给他人。它仍应主要作为字段、数据质量和转换流程的参考资料。

### 1.3 USDA 子集选择

USDA 条目选择顺序：

1. **Foundation Foods**：优先用于有对应条目的新鲜、未加工或轻度加工食材；
2. **SR Legacy**：Foundation Foods 没有合适条目时，用于补足常见基础食材的覆盖；
3. 不使用 **Branded Foods**、**FNDDS**、**Experimental Foods** 作为 MVP 公共库来源。

Branded Foods 对应具体品牌与包装，应由用户 Nutrition DB 的 Food Product / Food Version 表达。FNDDS 含有调查用途的复合食品描述；复杂菜肴、外卖和无法可靠标准化的食物保持 AI estimate 路径，不假装是通用食材。

## 2. 收录边界

首个资源包目标为约 100 个高频、可明确区分状态的通用食材，按实际使用再通过你的本地构建扩充。该 100 个条目优先从中国来源数据选取；USDA 用于明确标识的补充。首批配额如下：

| 类别 | 目标 | 例子 |
| --- | ---: | --- |
| 肉、禽、蛋、鱼和海鲜 | 30 | 鸡胸肉（生/熟）、鸡蛋、三文鱼、虾仁 |
| 主食、谷物和豆类 | 20 | 米饭（熟）、大米（生）、燕麦、红薯、豆腐 |
| 奶与常见饮品 | 10 | 牛奶、酸奶、无糖豆浆 |
| 蔬菜、菌菇、海藻 | 25 | 西兰花、番茄、黄瓜、菠菜、香菇 |
| 水果、坚果、油脂和常见调味料 | 15 | 香蕉、苹果、花生、橄榄油、生抽 |

这不是“覆盖所有中国食物”的承诺。它是稳定的默认值集合：未命中时优先让 Agent 提问、使用用户个人食品库或明确标为 AI estimate，而不是把错误或模糊的条目塞进公共库。

### 2.1 必须拆分的属性

每个条目只对应一种可计算状态。以下属性不能被别名或模型默认省略：

- 生 / 熟 / 焯水 / 油炸等显著影响营养的烹饪状态；
- 去皮 / 带皮、可食部分等明显影响重量或营养的形态；
- 全脂 / 脱脂等营养组成不同的产品类型；
- 固体 / 液体的计量基准。

例如“鸡胸肉”必须返回“生”与“熟”候选，让用户选择；别名表绝不能偷偷选其中一个。

## 3. 资源格式

构建产物为 `ios/Resources/ReferenceFood/reference-foods.json`，随 App bundle 只读加载，不在运行时请求任何上游数据 API。每条记录使用 Vita 的稳定 ID；上游来源 ID 仅作为溯源字段，不能作为产品逻辑中唯一且永久的 ID。

```json
{
  "id": "vita.reference.chicken-breast.raw",
  "canonicalName": "鸡胸肉（生）",
  "aliases": ["鸡胸肉", "生鸡胸", "鸡胸"],
  "category": "poultry",
  "preparationState": "raw",
  "base": { "quantity": 100, "unit": "g" },
  "nutrients": {
    "energyKcal": 0,
    "proteinG": 0,
    "fatG": 0,
    "carbohydrateG": 0
  },
  "densityGPerMl": null,
  "source": {
    "provider": "USDA FoodData Central or authorized China food composition source",
    "dataType": "Foundation Foods or China Food Composition Table",
    "externalId": "source-specific-id",
    "retrievedFromRelease": "YYYY-MM",
    "attribution": "source-specific attribution and licence"
  }
}
```

上例是 schema 示例，营养值与外部 ID 不是可发布数据。所有实际条目均须可追溯到固定的来源发布包、来源 ID、授权状态和人工审阅记录。

所有公共库营养基准统一为每 `100g`；液体的 `ml` 输入只有在条目拥有经审阅的 `densityGPerMl` 时才可精确换算为克，否则 Agent 必须澄清或标为估算。不可将 `1ml = 1g` 当作无条件通用规则。

## 4. 构建流程

1. 用户在受 Git 忽略保护的本地目录提供中国来源数据；构建脚本只读取该目录，不将其复制到 tracked 路径。
2. 中国库无条目或属于国际食材时，下载 FDC 发布包；按 Foundation Foods 优先、SR Legacy 补充选择候选，不在 App 中保存或暴露 FDC API Key。
3. 审阅来源描述、可食状态、每 100g 宏量营养值和能量来源；不凭名称猜测生熟或把中美不同食品直接视为同一条目。
4. 为每条记录编写中文 canonical name 与有限、人工审核过的别名；可能指向多条记录的别名是允许的，但查询结果必须返回多个候选。
5. 转换为 Vita JSON，保留来源专属 ID、数据类型、下载发布月份/版次、地域属性与署名。
6. 运行校验后，将 JSON 编译进 bundle。

公共库对运行时是静态的，Consumption Item 会保存引用 ID 和营养快照；后续资源包修正不会回写历史饮食记录。构建记录中的 FDC 发布月份只用于追溯来源，不引入面向用户的版本或历史重算机制。

## 5. 校验要求

- 每条实际记录均有非空 Vita ID、canonical name、外部来源 ID、数据类型、地域属性与署名；
- 蛋白质、脂肪、碳水与能量为非负有限值，基准固定为 100g；
- 同一 `canonicalName + preparationState` 不能重复；
- 多义别名必须生成多个候选；没有候选时不能退化成静默模糊匹配；
- “品牌”“包装规格”“供应商”等字段不得进入公共条目；
- 数据来源与实际的获授权来源发布包抽样比对，构建检查必须失败而非自动猜测缺失营养素。

## 6. 署名与产品展示

在 App 的 Settings / About 中展示：

> Public nutrition reference values are derived from their labelled food-composition sources. USDA FoodData Central values are provided under CC0 1.0. Values are general references, not product-label values or medical advice.

中文界面对应展示：

> 公共营养参考值来源于条目所标示的食物成分数据源；USDA FoodData Central 数据采用 CC0 1.0。数值仅作通用食材参考，不等同于具体商品营养标签或医疗建议。

每个命中公共库的 Item 详情页显示其实际来源（如“中国食物成分表”或“USDA FoodData Central”）及食材状态；不能显示为用户个人 Nutrition DB 数据。
