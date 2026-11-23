"""Build the bundled catalog from USDA FoodData Central's April 2018 SR Legacy CSV archive.

Source: https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_csv_2018-04.zip
Usage: python3 backend/scripts/build_ingredient_catalog.py /path/to/archive.zip
"""

import csv
import io
import json
import sys
from pathlib import Path
from zipfile import ZipFile

CATEGORIES = {
    1: "Dairy & eggs", 2: "Herbs & spices", 4: "Fats & oils", 5: "Poultry",
    6: "Soups & sauces", 7: "Deli meats", 9: "Fruit", 10: "Pork", 11: "Vegetables",
    12: "Nuts & seeds", 13: "Beef", 15: "Fish & seafood", 16: "Beans & legumes",
    17: "Other meats", 18: "Breads & baking", 19: "Sweets", 20: "Grains & pasta",
}
NUTRIENTS = {"1008": "kcal", "1003": "protein", "1005": "carbs", "1004": "fat"}
output = Path(__file__).resolve().parents[2] / "apps/LyfeKit/Sources/LyfeKit/Food/Ingredients.json"

with ZipFile(sys.argv[1]) as archive:
    def rows(table):
        path = next(p for p in archive.namelist() if p.endswith(f"/{table}.csv"))
        with archive.open(path) as source:
            yield from csv.DictReader(io.TextIOWrapper(source, encoding="utf-8-sig"))

    foods = {}
    for row in rows("food"):
        category = CATEGORIES.get(int(row["food_category_id"]))
        name = row["description"].strip()
        # Names must fit the meal API without truncating cut or preparation details.
        if category and 0 < len(name) <= 60:
            foods[row["fdc_id"]] = dict(name=name, category=category, fdcID=int(row["fdc_id"]))
    for row in rows("food_nutrient"):
        food = foods.get(row["fdc_id"])
        nutrient = NUTRIENTS.get(row["nutrient_id"])
        if food and nutrient and row["amount"]:
            food[nutrient] = float(row["amount"])

catalog = {}
for food in foods.values():
    if all(0 <= food.get(k, -1) <= (900 if k == "kcal" else 100) for k in NUTRIENTS.values()):
        catalog.setdefault(food["name"].casefold(), food)
output.write_text("[\n" + ",\n".join(json.dumps(catalog[k], separators=(",", ":")) for k in sorted(catalog)) + "\n]\n")
print(f"Wrote {len(catalog)} foods")
