"""How a written amount becomes a number and a unit.

An ingredient is a quantity, a unit and a name, and every row a cook reads is
rendered from those three. The creator's phrase is a note beside them. This
module holds both halves of getting there: the fraction notation recipes are
actually written in, which the extraction schema accepts where a decimal is
expected, and the split that recovers a number and a unit from a phrase when
the model left them empty.

It lives under `contracts` rather than `extraction` because the guarantee is
about what the API stores and returns, and extraction is only one of the
writers.
"""

import re
from decimal import Decimal, InvalidOperation
from fractions import Fraction
from typing import Annotated, Any

from pydantic import BeforeValidator

#: The largest amount the wire contract can carry, and the precision it keeps.
#: A parse that cannot be stored is not an answer, so both are enforced here
#: rather than left to fail validation somewhere downstream.
MAX_QUANTITY = Decimal("1000000")
QUANTITY_PLACES = 6
MAX_UNIT_LENGTH = 50

# "1/2", "2/3", "1 1/2" — how recipes are actually written, and so how models
# write them back. Pydantic rejects them as decimals, and because a rejected
# field fails the whole payload, one "2/3 cup" used to discard an entire
# extraction: every ingredient, every step, over a notation choice.
_FRACTION = re.compile(r"^(?:(\d+)\s+)?(\d+)\s*/\s*(\d+)$")
_VULGAR = {
    "¼": Fraction(1, 4),
    "½": Fraction(1, 2),
    "¾": Fraction(3, 4),
    "⅐": Fraction(1, 7),
    "⅓": Fraction(1, 3),
    "⅔": Fraction(2, 3),
    "⅕": Fraction(1, 5),
    "⅖": Fraction(2, 5),
    "⅗": Fraction(3, 5),
    "⅘": Fraction(4, 5),
    "⅙": Fraction(1, 6),
    "⅚": Fraction(5, 6),
    "⅛": Fraction(1, 8),
    "⅜": Fraction(3, 8),
    "⅝": Fraction(5, 8),
    "⅞": Fraction(7, 8),
}

_VULGAR_CLASS = "".join(_VULGAR)
#: The amount at the head of a phrase, longest notation first so "1 1/2" is
#: never read as the 1 in front of it.
_LEADING_AMOUNT = re.compile(
    rf"""^\s*
    (?:
        \d+\s+\d+\s*/\s*\d+       # 1 1/2
      | \d+\s*/\s*\d+             # 1/2
      | \d+[{_VULGAR_CLASS}]      # 1½
      | [{_VULGAR_CLASS}]         # ½
      | \d+(?:\.\d+)?             # 2, 0.75
    )
    """,
    re.VERBOSE,
)
#: A unit is one word of letters. The token after the amount in "2 16oz cans"
#: is not one, and a row that counts packages is a count with no unit.
_LEADING_UNIT = re.compile(r"^\s*([^\W\d_]+\.?)", re.UNICODE)


def decimal_from_fraction(value: Any) -> Any:
    """Accept a fraction where a decimal is expected; pass anything else on.

    Left for pydantic to reject when it is neither, so genuinely bad input
    still fails rather than being coerced into a plausible number.
    """

    if not isinstance(value, str):
        return value
    text = value.strip()
    if not text:
        return value
    if text in _VULGAR:
        return _as_decimal(_VULGAR[text])
    # "1½"
    if len(text) > 1 and text[-1] in _VULGAR:
        whole = text[:-1].strip()
        if whole.isdigit():
            return _as_decimal(int(whole) + _VULGAR[text[-1]])
    match = _FRACTION.match(text)
    if match is None:
        return value
    whole_part, numerator, denominator = match.groups()
    if int(denominator) == 0:
        return value
    total = Fraction(int(numerator), int(denominator))
    if whole_part is not None:
        total += int(whole_part)
    return _as_decimal(total)


def _as_decimal(value: Fraction) -> Decimal:
    try:
        return round(Decimal(value.numerator) / Decimal(value.denominator), 6)
    except (InvalidOperation, ZeroDivisionError):  # pragma: no cover - guarded above
        return Decimal(0)


#: A decimal that also accepts the fractions recipes are written in.
RecipeDecimal = Annotated[Decimal, BeforeValidator(decimal_from_fraction)]


def split_quantity(text: str | None) -> tuple[Decimal | None, str | None]:
    """The number and unit at the head of a written amount.

    `quantityText` is contractually the amount alone — "2 cups", "100 g",
    "2 16oz cans" — so the first word after the number is the unit when it
    is a word at all. Nothing is guessed: a phrase with no leading number
    ("a splash", "to taste") gives up nothing, and the caller's answer to
    that is to mark the ingredient as carrying no quantity, never to invent
    one.

    A range yields its low end, which is the amount a cook starts with; the
    phrase itself stays on the ingredient as the note that says the rest.
    """

    if text is None:
        return None, None
    match = _LEADING_AMOUNT.match(text)
    if match is None:
        return None, None
    quantity = decimal_from_fraction(match.group().strip())
    if not isinstance(quantity, Decimal):
        try:
            quantity = Decimal(str(quantity))
        except InvalidOperation:  # pragma: no cover - the regex admits only numbers
            return None, None
    if quantity < 0 or quantity > MAX_QUANTITY:
        return None, None
    if -quantity.as_tuple().exponent > QUANTITY_PLACES:  # type: ignore[operator]
        quantity = round(quantity, QUANTITY_PLACES)
    unit_match = _LEADING_UNIT.match(text[match.end() :])
    unit = unit_match.group(1) if unit_match is not None else None
    if unit is not None and len(unit) > MAX_UNIT_LENGTH:
        unit = None
    return quantity, unit
