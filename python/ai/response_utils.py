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


# A bank's reference after a name: "10/12", "296582382", "#552", "COFJGHAMBWMY",
# "PAYPALSD99". Short numbers belong to the name: "Pier 1 Imports", "Forever 21".
_REFERENCE_RE = re.compile(r"^(?=\S*\d)(\S*/\S*|#\d+|#|[^#\s]{4,})$|^#$")
_ACH_WORDS = {"PPD", "ID", "WEB", "CCD", ""}


def short_name(name: str) -> str:
    """A payer or merchant name without the bank's reference numbers, so one person's
    or one source's transfers read as one: "Zelle payment from ALICE HUANG 296582382"
    and "ATM CASH DEPOSIT 10/12 5423 8TH AVE" become "Zelle payment from ALICE HUANG"
    and "ATM CASH DEPOSIT"; "172355 CLASSLINK PAYROLL PPD ID: 1364227403" becomes
    "CLASSLINK PAYROLL". A name that is only a reference stays as it is."""
    tokens = str(name or "").split()
    while len(tokens) > 1 and tokens[0].isdigit() and len(tokens[0]) >= 5:
        tokens.pop(0)  # "172355 CLASSLINK PAYROLL", not "99 Ranch Market"
    for i, token in enumerate(tokens):
        long_code = i == len(tokens) - 1 and i >= 4 and len(token) >= 10 and token.isalnum()
        if i and (_REFERENCE_RE.match(token) or long_code):
            tokens = tokens[:i]
            break
    while tokens and tokens[-1].rstrip(":#-").upper() in _ACH_WORDS:
        tokens.pop()
    return " ".join(tokens) or str(name or "")
