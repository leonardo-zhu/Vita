# 公共营养参考库构建

把本地数据源转换为 App 内置的 `ios/Resources/ReferenceFood/reference-foods.json`。规则见 [公共营养参考库规范](../../docs/reference-food-library.md)。只用 Python 标准库。

```bash
python3 -I tools/reference-food/build.py
cd ios && xcodegen generate   # 首次生成产物后需要重新生成工程，让它进入 bundle
```

## 输入

| 文件 | 内容 | 是否提交 |
| --- | --- | --- |
| `selection.usda.json` | USDA 条目清单：Vita ID、中文名、别名、类别、状态、FDC ID。不含营养值。 | 提交 |
| `private-data/usda/foundation-<发布日期>-json/` | USDA Foundation Foods JSON 发布包（`fdc.nal.usda.gov`，CC0） | 不提交 |
| `private-data/usda/sr-legacy-2018-04/` | USDA SR Legacy CSV 发布包（最终版） | 不提交 |
| `private-data/china/selection.json` | 中国来源条目清单 | 不提交（私有） |
| `private-data/china/sanotsu-*/` | 《中国食物成分表标准版（第 6 版）》识别矫正版 JSON（Sanotsu/china-food-composition-data） | 不提交（私有） |

中国清单中与 USDA 清单同一个 Vita ID 的条目会覆盖 USDA 条目：中国日常食材以中国数据为准，USDA 只补充中国库没有的国际食材。没有中国数据时，构建只用 USDA 清单。

## 两层收录

- 精选层：两份清单中的条目（`tier: core`），人工审定名称与别名。
- 扩展层：中国数据中未进入精选层的其余条目（`tier: extended`），自动整理名称与别名；品牌产品与缺项条目跳过。App 查询时精选层没有命中才查扩展层。

## 取值规则

- USDA 能量依次取 Energy（1008）、Atwater Specific（2048）、Atwater General（2047）；碳水为差减法（1005）。
- 中国数据为每 100 g 可食部；`Tr`（微量）按 0 计，`—` 或空值视为缺失，带 `*` 的计算值去掉星号使用并在 `source.notes` 记录。
- 任一条目缺少能量、蛋白质、脂肪或碳水，或出现负值，构建失败，不猜测。
- `expectDescription` / `expectName` 用于发现来源 ID 指向的条目与审阅时不同。
- 密度只给经确认的液体（牛奶约 1.03、植物油约 0.91–0.92）；其他液体按 ml 输入时须澄清或估算。

## 已知缺口

- 下载的中国数据不含调味品类，酱油、白砂糖、蜂蜜暂用 USDA 值。
