"""Build the locked public-domain text-only extraction corpora.

Inputs are text produced with ``pdftotext -layout`` from the official NHLBI
*Deliciously Healthy Dinners* PDF and the selected USDA CACFP six-serving
recipe PDFs. The generated fixtures retain recipe text only; no photographs
or other PDF images are read or stored.
"""

import argparse
import hashlib
import json
import re
from decimal import Decimal
from pathlib import Path
from urllib.parse import quote, unquote

NHLBI_URL = "https://www.nhlbi.nih.gov/sites/default/files/publications/10-2921.pdf"
USDA_ROOT = "https://www.fns.usda.gov/sites/default/files/resource-files/"
RETRIEVED_AT = "2026-08-24"
LICENSE = "usGovernmentPublicDomain"
NHLBI_ATTRIBUTION = (
    "National Heart, Lung, and Blood Institute, Keep the Beat Recipes: "
    "Deliciously Healthy Dinners, NIH Publication No. 10-2921."
)
USDA_ATTRIBUTION = (
    "USDA Food and Nutrition Service, CACFP Home Childcare 6-Serving Recipe Project."
)

_VULGAR = "¼½¾⅐⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞"
_NUMBER = (
    rf"(?:\d+\s+(?:\d+/\d+|[{_VULGAR}])|\d+/\d+|"
    rf"\d+(?:\.\d+)?|[{_VULGAR}])"
)
_UNITS = {
    "c",
    "cup",
    "cups",
    "tbsp",
    "tsp",
    "oz",
    "lb",
    "lbs",
    "g",
    "kg",
    "can",
    "cans",
    "package",
    "packages",
}
_USDA_CALCULATED_TUNING = {
    "Baked_Beans_6_Servings.txt",
    "Brown_Rice_Pilaf_6_Servings.txt",
    "Corn_Edamame_Blend_6_Servings.txt",
    "Honey_Lime_Chicken_6_Servings.txt",
    "Macaroni_and_Cheese_6_Servings.txt",
}
_USDA_CALCULATED_HELD_OUT = {
    "Spiced%20Oatmeal%206%20Servings.txt",
    "Strawberry%20Smoothie%20Bowl%206%20Servings.txt",
    "Turkey_and_Dressing_6_Servings.txt",
    "Vegetable_Chili_6_Servings.txt",
}


def _decimal(value: str) -> Decimal:
    return Decimal(value.replace(",", ""))


def _wire(value: Decimal) -> str:
    return format(value.normalize(), "f")


def _clean(text: str) -> str:
    lines = [
        line.rstrip()
        for line in text.replace("\f", "").splitlines()
        if not (
            "Food and Nutrition Service | USDA is an equal opportunity" in line
            or (
                "deliciously healthy dinners" in line.casefold()
                and re.search(r"\s\d+\s*$", line)
            )
        )
    ]
    return "\n".join(lines).strip()


def _title(text: str, fallback: str) -> str:
    lines = text.splitlines()
    first_index = next(
        (
            index
            for index, line in enumerate(lines)
            if line.strip() and "United States Department of Agriculture" not in line
        ),
        None,
    )
    if first_index is None:
        return fallback
    first = re.split(r"\s{2,}(?:Prep|Cook) time:", lines[first_index])[0].strip()
    if not first or first.casefold().startswith(("main dishes", "side dishes")):
        return fallback
    if first.casefold().endswith((" with", " and", " of", "-style")):
        for line in lines[first_index + 1 : first_index + 6]:
            candidate = line.strip()
            if candidate and "time:" not in candidate.casefold():
                first = f"{first} {candidate}"
                break
    return first.replace("(continued)", "").strip()


def _ingredient_pair(text: str) -> dict[str, str]:
    if "Ingredients" in text:
        text = text.split("Ingredients", 1)[1]
    pattern = re.compile(rf"^\s*({_NUMBER})(?:\s+([A-Za-z]+))?\s+(.+?)\s{{3,}}", re.M)
    for match in pattern.finditer(text):
        amount, maybe_unit, name = match.groups()
        candidate_name = (
            name
            if maybe_unit and maybe_unit.casefold() in _UNITS
            else f"{maybe_unit} {name}"
            if maybe_unit
            else name
        )
        if candidate_name.casefold().startswith(
            ("preheat", "heat", "combine", "add", "place", "serve", "cook")
        ):
            continue
        if maybe_unit and maybe_unit.casefold() in _UNITS:
            quantity = f"{amount} {maybe_unit}"
        else:
            quantity = amount
            name = candidate_name
        name = re.sub(
            rf"^or\s+{_NUMBER}\s+(?:oz|lb|lbs|g|kg)\s+",
            "",
            name,
            flags=re.I,
        )
        name = re.split(r"\s{2,}|\s+\d+\s{2,}", name)[0].strip(" .")
        if name:
            return {"name": name[:300], "quantity": quantity}
    raise ValueError("recipe has no parseable ingredient line")


def _step_phrase(text: str) -> str:
    patterns = (
        r"\s{3,}\d+\s{2,}([A-Z][^\n]{8,})",
        r"(?m)^\s*1\s{2,}([A-Z][^\n]{8,})",
    )
    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            words = match.group(1).strip().split()
            return " ".join(words[:8]).rstrip(".,:;")
    for verb in ("Preheat", "Combine", "Heat", "Add", "Place", "Cook", "Mix"):
        match = re.search(rf"\b{verb}\b[^\n]{{5,}}", text)
        if match:
            return " ".join(match.group(0).split()[:8]).rstrip(".,:;")
    raise ValueError("recipe has no parseable direction")


def _structure(text: str, cook_minutes: str | None) -> dict[str, object]:
    return {
        "statedCookTimeMinutes": cook_minutes,
        "ingredientNameQuantities": [_ingredient_pair(text)],
        "orderedStepPhrases": [_step_phrase(text)],
    }


def _nutrition(
    *,
    servings: Decimal,
    calories: str,
    protein: str,
    carbohydrate: str,
    fat: str,
) -> dict[str, str]:
    return {
        "servings": _wire(servings),
        "calories": _wire(_decimal(calories) * servings),
        "proteinGrams": _wire(_decimal(protein) * servings),
        "carbohydrateGrams": _wire(_decimal(carbohydrate) * servings),
        "fatGrams": _wire(_decimal(fat) * servings),
    }


def _without_nutrition(text: str) -> str:
    return re.sub(
        r"\n\s*Nutrients Per Servings?:.*\Z",
        "",
        text,
        flags=re.S | re.I,
    ).strip()


def _usda_case(path: Path, *, index: int, held_out: bool) -> dict[str, object]:
    raw = _clean(path.read_text())
    servings_match = re.search(r"Makes:\s*(\d+(?:\.\d+)?)\s+servings", raw, re.I)
    nutrients = re.search(
        r"Nutrients Per Servings?:\s*Calories\s+(\d+(?:\.\d+)?)\s*,?\s*"
        r"Protein\s+(\d+(?:\.\d+)?)\s*g\s*,?\s*"
        r"Carbohydrates\s+(\d+(?:\.\d+)?)\s*g.*?"
        r"Total Fat\s+(\d+(?:\.\d+)?)\s*g",
        raw,
        re.S | re.I,
    )
    if servings_match is None or nutrients is None:
        raise ValueError(f"missing USDA yield or nutrition: {path.name}")
    servings = _decimal(servings_match.group(1))
    cook = re.search(r"Cooking Time:\s*(\d+(?:\.\d+)?)\s+minutes", raw, re.I)
    calculated = path.name in (
        _USDA_CALCULATED_HELD_OUT if held_out else _USDA_CALCULATED_TUNING
    )
    evidence = _without_nutrition(raw) if calculated else raw
    source_name = path.with_suffix(".pdf").name
    source_url = f"{USDA_ROOT}{quote(source_name, safe='%_-')}"
    label = "held-usda" if held_out else "tuning-usda"
    title = unquote(path.stem).replace("_", " ")
    title = re.sub(r"\s+6\s+Servings$", "", title, flags=re.I)
    return {
        "id": f"{label}-{index:03d}",
        "cacheKey": f"{label}-{index:03d}",
        "sourceURL": source_url,
        "retrievedAt": RETRIEVED_AT,
        "license": LICENSE,
        "attribution": USDA_ATTRIBUTION,
        "expectedNutritionBasis": ("usdaCalculated" if calculated else "creatorStated"),
        "evidence": {
            "title": title,
            "description": "Official USDA standardized recipe.",
            "linkedDocumentText": evidence,
        },
        "nutrition": _nutrition(
            servings=servings,
            calories=nutrients.group(1),
            protein=nutrients.group(2),
            carbohydrate=nutrients.group(3),
            fat=nutrients.group(4),
        ),
        "structure": _structure(raw, cook.group(1) if cook else None),
    }


def _nhlbi_cases(path: Path) -> list[dict[str, object]]:
    pages = path.read_text().split("\f")
    cases: list[dict[str, object]] = []
    for page_index, page in enumerate(pages):
        if (
            "yield:" not in page.casefold()
            or "each serving provides:" not in page.casefold()
        ):
            continue
        source = page
        if "(continued)" in "\n".join(page.splitlines()[:8]).casefold():
            source = f"{pages[page_index - 1]}\n{page}"
        source = _clean(source)
        yield_match = re.search(
            r"yield:\s*(?:each serving provides:\s*)?"
            r"(\d+(?:\.\d+)?)\s+servings",
            source,
            re.I,
        )
        nutrients = {
            field: re.search(pattern, source, re.I)
            for field, pattern in {
                "calories": r"calories\s+(\d+(?:\.\d+)?)",
                "protein": r"protein\s+(\d+(?:\.\d+)?)\s*g",
                "carbohydrate": r"carbohydrates\s+(\d+(?:\.\d+)?)\s*g",
                "fat": r"total fat\s+(\d+(?:\.\d+)?)\s*g",
            }.items()
        }
        if yield_match is None or any(value is None for value in nutrients.values()):
            missing = [key for key, value in nutrients.items() if value is None]
            if yield_match is None:
                missing.append("yield")
            raise ValueError(
                f"missing NHLBI {', '.join(missing)} on page {page_index + 1}"
            )
        servings = _decimal(yield_match.group(1))
        top = "\n".join(source.splitlines()[:12])
        timing = re.search(
            r"Prep time:\s*Cook time:\s*\n?\s*(\d+(?:\.\d+)?)\s+minutes\s*"
            r"\n?\s*(\d+(?:\.\d+)?)\s+minutes",
            top,
            re.I,
        )
        if timing is None:
            timing = re.search(
                r"Cook time:\s*(\d+(?:\.\d+)?)\s+minutes",
                top,
                re.I,
            )
            cook = timing.group(1) if timing else None
        else:
            cook = timing.group(2)
        number = len(cases) + 1
        nutrition_values = {
            key: value.group(1) for key, value in nutrients.items() if value
        }
        cases.append(
            {
                "id": f"held-nhlbi-{number:03d}",
                "cacheKey": f"held-nhlbi-{number:03d}",
                "sourceURL": f"{NHLBI_URL}#page={page_index + 1}",
                "retrievedAt": RETRIEVED_AT,
                "license": LICENSE,
                "attribution": NHLBI_ATTRIBUTION,
                "expectedNutritionBasis": "creatorStated",
                "evidence": {
                    "title": _title(source, f"NHLBI dinner recipe {number}"),
                    "description": "Official NHLBI heart-healthy dinner recipe.",
                    "linkedDocumentText": source,
                },
                "nutrition": _nutrition(
                    servings=servings,
                    calories=nutrition_values["calories"],
                    protein=nutrition_values["protein"],
                    carbohydrate=nutrition_values["carbohydrate"],
                    fat=nutrition_values["fat"],
                ),
                "structure": _structure(source, cook),
            }
        )
    if len(cases) != 75:
        raise ValueError(f"expected 75 NHLBI recipes, found {len(cases)}")
    return cases


def _safety_cases() -> list[dict[str, object]]:
    descriptions = [
        "Dinner was incredible tonight.",
        "You need to try this comfort food.",
        "Full recipe coming soon.",
        "Sunday cooking with the family.",
        "The crunch at the end is everything.",
        "Save this idea for later.",
        "A quick weeknight favorite.",
        "Link is unavailable.",
        "Recipe in my private newsletter.",
        "Guess what I made today.",
        "This sauce changed my life.",
        "Meal prep inspiration.",
        "No measurements, I cook with my heart.",
        "A cozy bowl for a rainy day.",
        "Part two has the recipe.",
        "Grandma taught me this dish.",
        "Testing a new kitchen setup.",
        "Would you eat this for breakfast?",
        "The written recipe was removed.",
        "More details in a deleted post.",
    ]
    return [
        {
            "id": f"safety-no-match-{index:03d}",
            "sourceURL": f"https://example.invalid/sparse/{index:03d}",
            "license": "synthetic",
            "attribution": "Ladle synthetic sparse-source safety fixture.",
            "expectedOutcome": "insufficientTextEvidence",
            "evidence": {
                "title": f"Sparse cooking post {index}",
                "description": description,
                "transcript": [],
                "linkedDocumentTexts": [],
            },
        }
        for index, description in enumerate(descriptions, start=1)
    ]


def _digest(cases: list[dict[str, object]], safety: list[dict[str, object]]) -> str:
    encoded = json.dumps(
        {"cases": cases, "safetyCases": safety},
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def _write(
    path: Path,
    *,
    name: str,
    partition: str,
    cases: list[dict[str, object]],
    safety: list[dict[str, object]],
) -> None:
    payload = {
        "corpusName": name,
        "fixtureVersion": "public-domain-v1",
        "partition": partition,
        "referenceStatus": "verified",
        "corpusDigest": _digest(cases, safety),
        "cases": cases,
        "safetyCases": safety,
    }
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nhlbi-text", type=Path, required=True)
    parser.add_argument("--usda-text-dir", type=Path, required=True)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).parents[1] / "tests/fixtures/evaluation",
    )
    args = parser.parse_args()

    usda_paths = sorted(args.usda_text_dir.glob("*.txt"))
    if len(usda_paths) != 25:
        raise ValueError(f"expected 25 USDA recipes, found {len(usda_paths)}")
    tuning = [
        _usda_case(path, index=index, held_out=False)
        for index, path in enumerate(usda_paths[:20], start=1)
    ]
    held_usda = [
        _usda_case(path, index=index, held_out=True)
        for index, path in enumerate(usda_paths[20:], start=1)
    ]
    held = [*_nhlbi_cases(args.nhlbi_text), *held_usda]
    safety = _safety_cases()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    _write(
        args.output_dir / "text-only-tuning.json",
        name="text-only-tuning",
        partition="tuning",
        cases=tuning,
        safety=[],
    )
    _write(
        args.output_dir / "text-only-held-out.json",
        name="text-only-held-out",
        partition="heldOut",
        cases=held,
        safety=safety,
    )
    print(f"wrote tuning={len(tuning)} heldOut={len(held)} safety={len(safety)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
