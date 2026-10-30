"""构建公共营养参考库 reference-foods.json（docs/reference-food-library.md §4）。

输入：
  - tools/reference-food/selection.usda.json：人工审定的 USDA 条目清单（只有 ID、名称与来源 ID，不含营养值，可提交）。
  - private-data/china/selection.json：中国来源条目清单（私有，Git 忽略）。与 USDA 清单同一个 Vita ID 时，
    中国条目优先（§1：中国日常食材以中国数据为准，USDA 只作补充）。
  - private-data/usda/、private-data/china/：两个来源的本地数据（Git 忽略）。
输出：
  - ios/Resources/ReferenceFood/reference-foods.json（Git 忽略），随 App bundle 只读加载。

校验不通过时整体失败，不猜测、不补全缺失营养素（§5）。只用 Python 标准库：

    python3 -I tools/reference-food/build.py
"""

import json
import re
import sys
import unicodedata
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import china  # noqa: E402
import usda  # noqa: E402

USDA_SELECTION = ROOT / "tools/reference-food/selection.usda.json"
CHINA_SELECTION = ROOT / "private-data/china/selection.json"
USDA_ROOT = ROOT / "private-data/usda"
CHINA_ROOT = ROOT / "private-data/china"
OUTPUT = ROOT / "ios/Resources/ReferenceFood/reference-foods.json"

USDA_ATTRIBUTION = "U.S. Department of Agriculture, Agricultural Research Service. FoodData Central. CC0 1.0."
CHINA_PROVIDER = "中国食物成分表标准版（第6版）"
CHINA_ATTRIBUTION = "杨月欣主编《中国食物成分表标准版（第6版）》，北京大学医学出版社；经 Sanotsu/china-food-composition-data 识别与人工矫正。仅限本人私有构建，不得分发。"
REQUIRED = ("id", "canonicalName", "aliases", "category", "preparationState", "source")


class BuildError(Exception):
    pass


def normalize(name):
    """与 App 内查询一致：全角转半角、小写、去空白。"""
    return "".join(unicodedata.normalize("NFKC", name).lower().split())


def number(value):
    """保留来源精度，最多两位小数，输出为 JSON 数字。"""
    quantized = Decimal(value).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP).normalize()
    return int(quantized) if quantized == quantized.to_integral() else float(quantized)


def usda_entry(entry, datasets):
    source = entry["source"]
    dataset = datasets.get(source["dataset"])
    if dataset is None:
        raise BuildError(f"{entry['id']}: 本地没有 {source['dataset']} 数据包")
    food = dataset.get(source["fdcId"])
    if food is None:
        raise BuildError(f"{entry['id']}: {source['dataset']} 中没有 FDC {source['fdcId']}")
    energy, energy_source = food.energy_kcal()
    values = {
        "energyKcal": energy,
        "proteinG": food.nutrients.get(usda.PROTEIN),
        "fatG": food.nutrients.get(usda.FAT),
        "carbohydrateG": food.nutrients.get(usda.CARBOHYDRATE),
    }
    missing = [key for key, value in values.items() if value is None]
    if missing:
        raise BuildError(f"{entry['id']}: FDC {food.fdc_id}（{food.description}）缺少 {', '.join(missing)}")
    negative = [key for key, value in values.items() if value < 0]
    if negative:
        raise BuildError(f"{entry['id']}: FDC {food.fdc_id} 的 {', '.join(negative)} 为负值，请换条目")
    expected = entry.get("expectDescription")
    if expected and expected != food.description:
        raise BuildError(f"{entry['id']}: FDC {food.fdc_id} 的描述是“{food.description}”，与审阅时的“{expected}”不符")
    return {
        "nutrients": {key: number(value) for key, value in values.items()},
        "source": {
            "provider": "USDA FoodData Central",
            "dataType": food.dataset,
            "externalId": f"fdc:{food.fdc_id}",
            "retrievedFromRelease": food.release,
            "region": "US",
            "description": food.description,
            "energyNutrientId": energy_source,
            "attribution": USDA_ATTRIBUTION,
        },
    }


def china_entry(entry, datasets):
    source = entry["source"]
    foods = datasets.get("china-fct6")
    if foods is None:
        raise BuildError(f"{entry['id']}: 本地没有中国食物成分数据")
    food = foods.get(source["foodCode"])
    if food is None:
        raise BuildError(f"{entry['id']}: 中国数据中没有食物编码 {source['foodCode']}")
    expected = entry.get("expectName")
    if expected and expected != food.name:
        raise BuildError(f"{entry['id']}: 编码 {food.code} 是“{food.name}”，与审阅时的“{expected}”不符")
    nutrients, notes = {}, []
    for key in china.FIELDS:
        value, note = food.value(key)
        if value is None:
            raise BuildError(f"{entry['id']}: {food.code}（{food.name}）的 {key} {note}")
        if value < 0:
            raise BuildError(f"{entry['id']}: {food.code} 的 {key} 为负值")
        nutrients[key] = number(value)
        if note:
            notes.append(f"{key}：{note}")
    return {
        "nutrients": nutrients,
        "source": {
            "provider": CHINA_PROVIDER,
            "dataType": "China Food Composition Tables 6th ed.",
            "externalId": f"cfct6:{food.code}",
            "retrievedFromRelease": food.release,
            "region": food.remark if food.remark and food.remark not in ("—", "-") else "CN",
            "description": food.name,
            "edibleFraction": number(Decimal(food.edible) / 100) if food.edible and food.edible.isdigit() else None,
            "notes": notes,
            "attribution": CHINA_ATTRIBUTION,
        },
    }


# 中国数据大类 → Vita 类别。
CHINA_CATEGORIES = [
    ("畜肉类及其制品-猪", "pork"), ("畜肉类及其制品-牛", "beef"), ("畜肉类及其制品-羊", "lamb"), ("畜肉类", "meat"),
    ("禽肉类", "poultry"), ("蛋类", "egg"), ("鱼虾蟹贝类-鱼", "fish"), ("鱼虾蟹贝类", "seafood"),
    ("乳类", "dairy"), ("谷类", "grain"), ("薯类淀粉", "tuber"), ("干豆类", "legume"), ("蔬菜类", "vegetable"),
    ("菌藻类", "mushroom"), ("水果类", "fruit"), ("坚果种子类", "nut"), ("植物油", "oil"), ("动物油脂", "oil"),
]
RAW_BY_DEFAULT = {"pork", "beef", "lamb", "meat", "poultry", "egg", "fish", "seafood", "vegetable", "mushroom", "fruit"}


def china_category(category):
    return next((key for prefix, key in CHINA_CATEGORIES if category.startswith(prefix)), "other")


def infer_state(name, category):
    """从来源名称推断状态，只用于展示与去重，不参与营养计算。"""
    if "罐头" in name:
        return "canned"
    if re.search(r"[煮蒸烤炒炸卤酱熏熟烧焖炖煎腌]", name):
        return "cooked"
    if re.search(r"干|脱水|粉", name):
        return "dried"
    if re.search(r"生|鲜", name):
        return "raw"
    return "raw" if category in RAW_BY_DEFAULT else "asSold"


GENERIC_DAIRY_WORDS = {"全脂", "脱脂", "低脂", "半脱脂", "速溶", "冻", "鲜", "成熟乳", "初乳", "过渡乳", "甜", "淡", "原味", "干酪", "高钙", "调味", "果料", "果粒", "高蛋白"}


def generic_dairy(name):
    parts = [p for group in re.findall(r"（([^）]*)）", name) for p in re.split(r"[，,、]", group)]
    return all(part.strip() in GENERIC_DAIRY_WORDS for part in parts)


def extended_entries(curated, datasets):
    """扩展层：中国数据中未进入精选层的非品牌条目，名称取自原书，［］中的写法作为别名。

    自动整理的条目不做人工审阅，所以只在精选层没有命中时才参与查询（App 端 ReferenceFoodCatalog.search）。
    缺少核心营养素、负值或品牌产品直接跳过，不补数值。
    """
    foods = datasets.get("china-fct6")
    if not foods:
        return [], {}
    used_codes = {entry["source"].get("foodCode") for entry in curated}
    used_names = {(normalize(entry["canonicalName"]), entry["preparationState"]) for entry in curated}
    skipped = {"精选层已收录": 0, "品牌产品": 0, "缺少核心营养素": 0}
    entries = []
    for food in sorted(foods.values(), key=lambda f: f.code):
        if food.code in used_codes:
            skipped["精选层已收录"] += 1
            continue
        # 乳类的括号里多是品牌或商品名（如“全脂奶粉（雀巢）”），只保留括号内全是通用描述的条目和代表值。
        if "牌" in food.name or (food.category.startswith("乳类") and not food.code.endswith("x") and not generic_dairy(food.name)):
            skipped["品牌产品"] += 1
            continue
        values = [food.value(key)[0] for key in china.FIELDS]
        if any(value is None or value < 0 for value in values):
            skipped["缺少核心营养素"] += 1
            continue
        bracketed = re.findall(r"［([^］]*)］", food.name)
        canonical = re.sub(r"［[^］]*］", "", food.name).strip()
        aliases = [alias.strip() for group in bracketed for alias in re.split(r"[、，,]", group) if alias.strip()]
        if canonical != food.name:
            aliases.insert(0, food.name)
        category = china_category(food.category)
        state = infer_state(canonical, category)
        if (normalize(canonical), state) in used_names:
            region = food.remark if food.remark and food.remark not in ("—", "-") else food.code
            canonical = f"{canonical}（{region}）"
            if (normalize(canonical), state) in used_names:
                canonical = f"{canonical}（{food.code}）"
        used_names.add((normalize(canonical), state))
        entries.append({
            "id": f"vita.reference.cfct6.{food.code.lower()}",
            "canonicalName": canonical,
            "aliases": list(dict.fromkeys(a for a in aliases if a != canonical)),
            "category": category,
            "preparationState": state,
            "source": {"dataset": "china-fct6", "foodCode": food.code},
            "tier": "extended",
        })
    return entries, skipped


def selections():
    """USDA 清单打底，中国清单按 ID 覆盖或追加。"""
    entries = {}
    if USDA_SELECTION.exists():
        for entry in json.loads(USDA_SELECTION.read_text())["foods"]:
            entries[entry["id"]] = entry
    overridden = 0
    if CHINA_SELECTION.exists():
        for entry in json.loads(CHINA_SELECTION.read_text())["foods"]:
            overridden += entry["id"] in entries
            entries[entry["id"]] = entry
    return list(entries.values()), overridden


def build():
    datasets = {}
    if USDA_ROOT.exists():
        datasets.update(usda.load_all(USDA_ROOT))
    datasets.update(china.load_all(CHINA_ROOT))
    entries, overridden = selections()
    if not entries:
        raise BuildError("没有任何条目清单")
    extended, skipped = extended_entries(entries, datasets)
    entries += extended

    output, seen_ids, seen_names = [], set(), set()
    for entry in entries:
        for field in REQUIRED:
            if not entry.get(field) and entry.get(field) != []:
                raise BuildError(f"{entry.get('id', '?')}: 缺少 {field}")
        if not entry["id"].startswith("vita.reference."):
            raise BuildError(f"{entry['id']}: ID 必须以 vita.reference. 开头")
        if entry["id"] in seen_ids:
            raise BuildError(f"重复 ID {entry['id']}")
        seen_ids.add(entry["id"])
        name_key = (normalize(entry["canonicalName"]), entry["preparationState"])
        if name_key in seen_names:
            raise BuildError(f"{entry['id']}: canonicalName + preparationState 重复")
        seen_names.add(name_key)
        for banned in ("brand", "brandOrSupplier", "package", "supplier"):
            if banned in entry:
                raise BuildError(f"{entry['id']}: 公共条目不得包含 {banned}")

        dataset = entry["source"]["dataset"]
        if dataset.startswith("usda-"):
            resolved = usda_entry(entry, datasets)
        elif dataset == "china-fct6":
            resolved = china_entry(entry, datasets)
        else:
            raise BuildError(f"{entry['id']}: 未知数据源 {dataset}")

        density = entry.get("densityGPerMl")
        if density is not None and density <= 0:
            raise BuildError(f"{entry['id']}: 密度必须为正")
        output.append({
            "id": entry["id"],
            "canonicalName": entry["canonicalName"],
            "aliases": entry["aliases"],
            "category": entry["category"],
            "preparationState": entry["preparationState"],
            "base": {"quantity": 100, "unit": "g"},
            "nutrients": resolved["nutrients"],
            "densityGPerMl": density,
            "source": resolved["source"],
            "tier": entry.get("tier", "core"),
        })

    # 别名可以指向多个条目（查询时返回全部候选），这里只报告精选层的，便于审阅。
    by_alias = {}
    for food in (f for f in output if f["tier"] == "core"):
        for name in [food["canonicalName"], *food["aliases"]]:
            by_alias.setdefault(normalize(name), []).append(food["id"])
    ambiguous = {name: ids for name, ids in by_alias.items() if len(set(ids)) > 1}

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n")
    by_source = {}
    for food in output:
        by_source[food["source"]["provider"]] = by_source.get(food["source"]["provider"], 0) + 1
    core = sum(1 for f in output if f["tier"] == "core")
    print(f"扩展层 {len(output) - core} 条；跳过 " + "，".join(f"{k} {v}" for k, v in skipped.items()))
    print(f"已生成 {OUTPUT.relative_to(ROOT)}：{len(output)} 条，其中精选层 {core} 条（{'，'.join(f'{k} {v}' for k, v in by_source.items())}；中国条目覆盖 USDA {overridden} 条）")
    for name, ids in sorted(ambiguous.items()):
        print(f"  多候选别名 {name}: {', '.join(sorted(set(ids)))}")


if __name__ == "__main__":
    try:
        build()
    except BuildError as error:
        print(f"构建失败：{error}", file=sys.stderr)
        sys.exit(1)
