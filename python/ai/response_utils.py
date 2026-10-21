"""Response formatting helpers shared by API routes."""

import re

from ai.validators import clamp_str


def confidence_label(score: float) -> str:
    value = float(score or 0.0)
    if value >= 0.75:
        return "high"
    if value >= 0.45:
        return "medium"
    return "low"


def short_copy(text: str) -> str:
    value = clamp_str(text, 220)
    if not value:
        return ""
    for sep in (". ", "! ", "? "):
        idx = value.find(sep)
        if idx > 0:
            return clamp_str(value[: idx + 1], 160)
    return clamp_str(value, 160)


def describe_plaid_amount(amount) -> str:
    """Label a signed Plaid amount by direction so neither users nor the LLM misread it.

    Plaid convention: positive = money out of the account (a purchase), negative = money in
    (a paycheck or refund). Printing the raw sign reads backwards ("+$50" for a purchase).
    """
    value = float(amount or 0)
    if value > 0:
        return f"spent ${value:.2f}"
    if value < 0:
        return f"received ${abs(value):.2f}"
    return "$0.00"


_UNGROUPED_DOLLARS_RE = re.compile(r"(?<![\d,])\$(\d{4,})(?=(\.\d+)?(?!\d|,\d))")


def group_dollar_amounts(text: str) -> str:
    """$1127.50 -> $1,127.50, the way the app shows money. Amounts already grouped stay."""
    return _UNGROUPED_DOLLARS_RE.sub(lambda m: f"${int(m.group(1)):,}", text)
