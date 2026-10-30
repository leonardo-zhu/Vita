"""读取本地 USDA FoodData Central 发布包（private-data/usda/，Git 忽略），只取能量与三大营养素。

Foundation Foods 用 JSON 包，SR Legacy 用 CSV 包。只用 Python 标准库。
"""

import csv
import json
from decimal import Decimal
from pathlib import Path

PROTEIN, FAT, CARBOHYDRATE = 1003, 1004, 1005
# 能量取值顺序：直接给出的能量 > Atwater 特定系数 > Atwater 通用系数。
ENERGY_PREFERENCE = (1008, 2048, 2047)


class Food:
    def __init__(self, dataset, release, fdc_id, description, category, nutrients):
        self.dataset = dataset
        self.release = release
        self.fdc_id = fdc_id
        self.description = description
        self.category = category
        self.nutrients = nutrients  # {nutrient_id: Decimal}，单位均为每 100 g

    def energy_kcal(self):
        for nutrient_id in ENERGY_PREFERENCE:
            if nutrient_id in self.nutrients:
                return self.nutrients[nutrient_id], nutrient_id
        return None, None


def load_foundation(directory: Path):
    """Foundation Foods JSON 包：{"FoundationFoods": [...]}。"""
    path = next(directory.glob("FoodData_Central_foundation_food_json_*.json"))
    release = path.stem.rsplit("_", 1)[-1]  # 如 2026-10-29
    foods = {}
    for item in json.loads(path.read_text())["FoundationFoods"]:
        nutrients = {}
        for entry in item["foodNutrients"]:
            if "amount" in entry and entry["nutrient"]["unitName"] in ("g", "kcal"):
                nutrients[entry["nutrient"]["id"]] = Decimal(str(entry["amount"]))
        foods[item["fdcId"]] = Food(
            "Foundation Foods", release, item["fdcId"], item["description"],
            (item.get("foodCategory") or {}).get("description"), nutrients,
        )
    return foods


def load_sr_legacy(directory: Path):
    """SR Legacy CSV 包：food.csv + food_nutrient.csv + food_category.csv。"""
    root = next(directory.glob("FoodData_Central_sr_legacy_food_csv_*"))
    release = root.name.rsplit("_", 1)[-1]  # 如 2018-04
    with open(root / "food_category.csv", newline="") as f:
        categories = {row["id"]: row["description"] for row in csv.DictReader(f)}
    foods = {}
    with open(root / "food.csv", newline="") as f:
        for row in csv.DictReader(f):
            fdc_id = int(row["fdc_id"])
            foods[fdc_id] = Food("SR Legacy", release, fdc_id, row["description"], categories.get(row["food_category_id"]), {})
    wanted = {PROTEIN, FAT, CARBOHYDRATE, *ENERGY_PREFERENCE}
    with open(root / "food_nutrient.csv", newline="") as f:
        for row in csv.DictReader(f):
            nutrient_id = int(row["nutrient_id"])
            if nutrient_id in wanted and row["amount"]:
                food = foods.get(int(row["fdc_id"]))
                if food:
                    food.nutrients[nutrient_id] = Decimal(row["amount"])
    return foods


def load_all(usda_root: Path):
    datasets = {}
    for directory in usda_root.iterdir():
        if directory.name.startswith("foundation-"):
            datasets["usda-foundation"] = load_foundation(directory)
        elif directory.name.startswith("sr-legacy-"):
            datasets["usda-sr-legacy"] = load_sr_legacy(directory)
    return datasets
