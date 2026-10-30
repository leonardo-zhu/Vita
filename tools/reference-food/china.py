"""读取本地《中国食物成分表标准版（第 6 版）》衍生 JSON（private-data/china/，Git 忽略，仅限本人私有构建）。

数据来自 Sanotsu/china-food-composition-data 的手动矫正版（docs/reference-food-library.md §1.2）。
营养值为每 100 g 可食部；数值以字符串存储：
  - "Tr"：原书标注的微量，按 0 计；
  - "—" 或空：未测定，视为缺失；
  - 末尾带 "*"：原书的计算值，去掉星号使用并记录。
"""

import json
from decimal import Decimal, InvalidOperation
from pathlib import Path

FIELDS = {"energyKcal": "energyKCal", "proteinG": "protein", "fatG": "fat", "carbohydrateG": "CHO"}


class Food:
    def __init__(self, item, category, release):
        self.code = item["foodCode"]
        self.name = item["foodName"]
        self.category = category
        self.release = release
        self.edible = item.get("edible")
        self.remark = item.get("remark") or ""
        self.raw = {key: item.get(field) for key, field in FIELDS.items()}

    def value(self, key):
        """返回 (Decimal 或 None, 说明)。"""
        text = (self.raw.get(key) or "").strip()
        if text in ("", "—", "-"):
            return None, "未测定"
        if text.lower() == "tr":
            return Decimal(0), "微量"
        note = None
        if text.endswith("*"):
            text, note = text[:-1], "计算值"
        try:
            return Decimal(text), note
        except InvalidOperation:
            return None, f"无法解析的值 {text!r}"


def load(directory: Path):
    """读取 merged_<大类>-<小类>.json，按 foodCode 建索引。"""
    foods = {}
    release = directory.name
    for path in sorted(directory.glob("merged_*.json")):
        category = path.stem.removeprefix("merged_")
        for item in json.loads(path.read_text()):
            foods[item["foodCode"]] = Food(item, category, release)
    return foods


def load_all(china_root: Path):
    datasets = {}
    for directory in sorted(china_root.iterdir()) if china_root.exists() else []:
        if directory.is_dir() and directory.name.startswith("sanotsu-"):
            datasets["china-fct6"] = load(directory)
    return datasets
