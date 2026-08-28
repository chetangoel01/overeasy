"""Deterministically copy explicit creator facts from text evidence."""

import re
from collections.abc import Iterable
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Literal

from ladle.contracts.recipes import RecipeReviewStatus
from ladle.recipes.template_clone import RecipeTemplate, TemplateNutrition

_NUMBER = r"\d[\d,]*(?:\.\d+)?"
_YIELD = re.compile(
    rf"\b(?:makes?|yields?)\s*:?\s*(?P<value>{_NUMBER})\s*"
    r"(?:servings?|portions?)\b",
    re.IGNORECASE,
)
_SERVES = re.compile(
    rf"\bserves\s*:?\s*(?P<value>{_NUMBER})(?:\s+(?:people|servings?))?\b",
    re.IGNORECASE,
)
_INTERLEAVED_YIELD = re.compile(
    rf"\byield\s*:\s*(?:each\s+serving\s+provides\s*:\s*)?"
    rf"(?P<value>{_NUMBER})\s*servings?\b",
    re.IGNORECASE,
)
_PANEL_MARKER = re.compile(
    r"(?P<whole>\bnutrition(?:\s+facts?)?\s+for\s+(?:the\s+)?"
    r"(?:entire|whole)\s+(?:recipe|batch)\b)"
    r"|(?P<per>\bnutrients?\s+per\s+servings?\b|\bnutrition\s+facts\b|"
    r"\beach\s+serving\s+provides\b|\bper\s+serving\s*:)",
    re.IGNORECASE,
)
_DURATION = (
    r"(?:\d+(?:\.\d+)?\s*(?:hours?|hrs?)"
    r"(?:\s+(?:and\s+)?\d+(?:\.\d+)?\s*(?:minutes?|mins?))?"
    r"|\d+(?:\.\d+)?\s*(?:minutes?|mins?))"
)
_STACKED_TIMES = re.compile(
    rf"\bprep(?:aration)?\s*time\s*:\s*"
    rf"cook(?:ing)?\s*time\s*:\s*"
    rf"(?P<prep>{_DURATION})\s*(?P<cook>{_DURATION})",
    re.IGNORECASE,
)
_LABELED_TIMES = {
    "preparation_minutes": re.compile(
        rf"\bprep(?:aration)?\s*time\s*:\s*(?P<duration>{_DURATION})",
        re.IGNORECASE,
    ),
    "cooking_minutes": re.compile(
        rf"\bcook(?:ing)?\s*time\s*:\s*(?P<duration>{_DURATION})",
        re.IGNORECASE,
    ),
    "total_minutes": re.compile(
        rf"\btotal\s*time\s*:\s*(?P<duration>{_DURATION})",
        re.IGNORECASE,
    ),
}


@dataclass(frozen=True)
class _Panel:
    scope: Literal["per", "whole"]
    calories: Decimal
    protein: Decimal
    carbohydrate: Decimal
    fat: Decimal
    saturated_fat: Decimal | None
    fiber: Decimal | None
    sugar: Decimal | None
    sodium: Decimal | None
    evidence: str


def _decimal(value: str) -> Decimal | None:
    try:
        result = Decimal(value.replace(",", ""))
    except InvalidOperation:
        return None
    return result if result >= 0 else None


def _unique_decimal(patterns: tuple[str, ...], text: str) -> Decimal | None:
    values = _decimal_values(patterns, text)
    return next(iter(values)) if len(values) == 1 else None


def _decimal_values(patterns: tuple[str, ...], text: str) -> set[Decimal]:
    return {
        value
        for pattern in patterns
        for match in re.finditer(pattern, text, re.IGNORECASE | re.MULTILINE)
        if (value := _decimal(match.group("value"))) is not None
    }


def _preferred_decimal(
    labeled: tuple[str, ...],
    amount_first: tuple[str, ...],
    text: str,
) -> Decimal | None:
    labeled_values = _decimal_values(labeled, text)
    if labeled_values:
        return next(iter(labeled_values)) if len(labeled_values) == 1 else None
    return _unique_decimal(amount_first, text)


def _yield(evidence: tuple[str, ...]) -> Decimal | None:
    values = {
        value
        for text in evidence
        for pattern in (_YIELD, _SERVES, _INTERLEAVED_YIELD)
        for match in pattern.finditer(text)
        if (value := _decimal(match.group("value"))) is not None and value > 0
    }
    return next(iter(values)) if len(values) == 1 else None


def _panel_values(block: str) -> tuple[Decimal, Decimal, Decimal, Decimal] | None:
    calories = _preferred_decimal(
        (rf"\bcalories?\s*:?\s*(?P<value>{_NUMBER})\b",),
        (rf"(?P<value>{_NUMBER})\s*(?:kcal|calories?)\b",),
        block,
    )
    protein = _preferred_decimal(
        (rf"\bprotein\s*:?\s*(?P<value>{_NUMBER})\s*(?:g|grams?)\b",),
        (rf"(?P<value>{_NUMBER})\s*(?:g|grams?)\s+(?:of\s+)?protein\b",),
        block,
    )
    carbohydrate = _preferred_decimal(
        (
            rf"\b(?:total\s+)?(?:carbohydrates?|carbs?)\s*:?\s*"
            rf"(?P<value>{_NUMBER})\s*(?:g|grams?)\b",
        ),
        (
            rf"(?P<value>{_NUMBER})\s*(?:g|grams?)\s+(?:of\s+)?"
            r"(?:carbohydrates?|carbs?)\b",
        ),
        block,
    )
    fat = _preferred_decimal(
        (
            rf"\btotal\s+fat\s*:?\s*(?P<value>{_NUMBER})\s*(?:g|grams?)\b",
            rf"(?:^|[,;\n])\s*fat\s*:?\s*(?P<value>{_NUMBER})\s*"
            r"(?:g|grams?)\b",
        ),
        (
            rf"(?P<value>{_NUMBER})\s*(?:g|grams?)\s+(?:of\s+)?"
            r"(?:total\s+)?fat\b",
        ),
        block,
    )
    if None in (calories, protein, carbohydrate, fat):
        return None
    assert calories is not None
    assert protein is not None
    assert carbohydrate is not None
    assert fat is not None
    return calories, protein, carbohydrate, fat


def _panels(evidence: tuple[str, ...]) -> list[_Panel]:
    panels: list[_Panel] = []
    for text in evidence:
        markers = list(_PANEL_MARKER.finditer(text))
        for index, marker in enumerate(markers):
            end = min(
                marker.start() + 2_000,
                markers[index + 1].start() if index + 1 < len(markers) else len(text),
            )
            block = text[marker.start() : end].strip()
            primary = _panel_values(block)
            if primary is None:
                continue
            panels.append(
                _Panel(
                    scope="whole" if marker.lastgroup == "whole" else "per",
                    calories=primary[0],
                    protein=primary[1],
                    carbohydrate=primary[2],
                    fat=primary[3],
                    saturated_fat=_unique_decimal(
                        (
                            rf"\bsaturated\s+fat\s*:?\s*(?P<value>{_NUMBER})\s*"
                            r"(?:g|grams?)\b",
                        ),
                        block,
                    ),
                    fiber=_unique_decimal(
                        (
                            rf"\b(?:total|dietary)\s+fiber\s*:?\s*"
                            rf"(?P<value>{_NUMBER})\s*(?:g|grams?)\b",
                        ),
                        block,
                    ),
                    sugar=_unique_decimal(
                        (
                            rf"\b(?:total\s+)?sugars?\s*:?\s*(?P<value>{_NUMBER})"
                            r"\s*(?:g|grams?)\b",
                        ),
                        block,
                    ),
                    sodium=_unique_decimal(
                        (
                            rf"\bsodium\s*:?\s*(?P<value>{_NUMBER})\s*"
                            r"(?:mg|milligrams?)\b",
                        ),
                        block,
                    ),
                    evidence=block,
                )
            )
    return panels


def _unique_panel(evidence: tuple[str, ...]) -> _Panel | None:
    panels = _panels(evidence)
    identities = {
        (value.scope, value.calories, value.protein, value.carbohydrate, value.fat)
        for value in panels
    }
    if len(identities) != 1:
        return None
    identity = next(iter(identities))
    return next(
        value
        for value in panels
        if (
            value.scope,
            value.calories,
            value.protein,
            value.carbohydrate,
            value.fat,
        )
        == identity
    )


def _minutes(value: str) -> int | None:
    hours_match = re.search(
        r"(?P<value>\d+(?:\.\d+)?)\s*(?:hours?|hrs?)",
        value,
        re.IGNORECASE,
    )
    minutes_match = re.search(
        r"(?P<value>\d+(?:\.\d+)?)\s*(?:minutes?|mins?)",
        value,
        re.IGNORECASE,
    )
    hours = _decimal(hours_match.group("value")) if hours_match else Decimal(0)
    minutes = _decimal(minutes_match.group("value")) if minutes_match else Decimal(0)
    if hours is None or minutes is None:
        return None
    total = hours * 60 + minutes
    return int(total) if total == total.to_integral_value() else None


def _times(evidence: tuple[str, ...]) -> dict[str, int]:
    found: dict[str, set[int]] = {field: set() for field in _LABELED_TIMES}
    for text in evidence:
        stacked = list(_STACKED_TIMES.finditer(text))
        for match in stacked:
            for field, group in (
                ("preparation_minutes", "prep"),
                ("cooking_minutes", "cook"),
            ):
                if (value := _minutes(match.group(group))) is not None:
                    found[field].add(value)
        direct_text = list(text)
        for match in stacked:
            direct_text[match.start() : match.end()] = " " * (
                match.end() - match.start()
            )
        remaining = "".join(direct_text)
        for field, pattern in _LABELED_TIMES.items():
            for match in pattern.finditer(remaining):
                if (value := _minutes(match.group("duration"))) is not None:
                    found[field].add(value)
    return {
        field: next(iter(values)) for field, values in found.items() if len(values) == 1
    }


def apply_creator_facts(
    template: RecipeTemplate,
    evidence: Iterable[str],
) -> RecipeTemplate:
    """Apply only unique, explicitly labeled facts found in source text."""

    texts = tuple(value for value in evidence if value.strip())
    stated_yield = _yield(texts)
    panel = _unique_panel(texts)
    updates: dict[str, object] = dict(_times(texts))
    resolved_fields = set(updates)

    if stated_yield is not None:
        updates.update(servings=stated_yield, servings_basis="stated")
        resolved_fields.add("servings")

    if panel is not None and (panel.scope == "per" or stated_yield is not None):
        updates["nutrition"] = TemplateNutrition(
            calories=panel.calories,
            protein_grams=panel.protein,
            carbohydrate_grams=panel.carbohydrate,
            fat_grams=panel.fat,
            saturated_fat_grams=panel.saturated_fat,
            fiber_grams=panel.fiber,
            sugar_grams=panel.sugar,
            sodium_milligrams=panel.sodium,
            serving_basis=Decimal(1) if panel.scope == "per" else stated_yield,
            is_estimated=False,
            basis="creatorStated",
            evidence=panel.evidence,
        )
        resolved_fields.add("nutrition")

    uncertainty_fields = {
        "preparation_minutes": {"preparationMinutes", "preparation_minutes"},
        "cooking_minutes": {"cookingMinutes", "cooking_minutes"},
        "total_minutes": {"totalMinutes", "total_minutes"},
    }
    resolved_uncertainties = {"servings", "nutrition"}
    resolved_uncertainties &= resolved_fields
    for field in resolved_fields:
        resolved_uncertainties.update(uncertainty_fields.get(field, set()))
    uncertainties = [
        value
        for value in template.uncertainties
        if value.field not in resolved_uncertainties
    ]
    updates["uncertainties"] = uncertainties
    if template.review_status == RecipeReviewStatus.NEEDS_REVIEW and not uncertainties:
        updates["review_status"] = RecipeReviewStatus.READY
    return template.model_copy(update=updates)
