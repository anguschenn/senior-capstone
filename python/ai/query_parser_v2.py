"""V2 query parser: normalize natural-language asks into canonical QuerySpec."""

import re

from .query_contracts import QuerySpec
from .time_scope_resolver import previous_month_key, selected_month_key
from .validators import clamp_str


def parse_query_v2(message, summary):
    text = clamp_str(message or "", 4000).lower()
    if not text:
        return QuerySpec()
    text = re.sub(r"\b(last|previous|prior|past)\s+mo\b", r"\1 month", text)
    text = re.sub(r"\b(previous|prior|past)\s+month\b", "last month", text)
    text = re.sub(r"\blst\b", "last", text)
    text = re.sub(r"\bspeding\b", "spending", text)
    text = re.sub(r"\bspendng\b", "spending", text)
    text = re.sub(r"\bcategry\b", "category", text)
    text = re.sub(r"\bcatgeory\b", "category", text)
    text = re.sub(r"\btransections\b", "transactions", text)
    text = re.sub(r"\btransacations\b", "transactions", text)
    text = re.sub(r"\bpls\b", "please", text)
    text = re.sub(r"\bthx\b", "thanks", text)
    text = re.sub(r"\bwanna\b", "want to", text)
    text = re.sub(r"\bgonna\b", "going to", text)
    text = re.sub(r"\bur\b", "your", text)
    text = re.sub(r"\bu\b", "you", text)
    text = re.sub(r"\bthis\s+mo\b", "this month", text)
    text = re.sub(r"\bcurrent\s+mo\b", "current month", text)
    text = re.sub(r"\bthis\s+yr\b", "this year", text)
    text = re.sub(r"\b(previous|prior)\s+year\b", "last year", text)
    # Remove noisy punctuation/emojis while preserving date separators.
    text = re.sub(r"[^a-z0-9\s\-/#]", " ", text)
    text = re.sub(r"\s+", " ", text).strip()

    scope = "unknown"
    if isinstance(summary, dict):
        scope = clamp_str(summary.get("scope", ""), 32) or "unknown"

    has_spending = (
        ("spending" in text) or ("expenses" in text) or bool(re.search(r"\bspend(ing)?\b", text))
    )
    has_change = any(
        token in text
        for token in (
            "increase",
            "increased",
            "up",
            "grew",
            "grow",
            "rose",
            "rise",
            "changed",
            "change",
            "higher",
            "lower",
            "decrease",
            "decreased",
            "down",
        )
    )
    has_cause = any(
        token in text
        for token in ("why", "caused", "cause", "what changed", "what drove", "how come", "reason")
    )
    if has_spending and "last month" in text and (has_change or has_cause):
        return QuerySpec(
            task_type="explain",
            metric="expenses",
            period_type="month",
            period_key=previous_month_key(summary),
            scope=scope,
            reason_mode="spending_change",
        )

    compare_like = (
        ("compare" in text)
        or (" vs " in text)
        or ("versus" in text)
        or ("difference" in text)
        or ("month over month" in text)
        or ("month-over-month" in text)
        or bool(re.search(r"\bmom\b", text))
        or bool(re.search(r"\bbetween\s+20\d{2}-\d{2}\s+and\s+20\d{2}-\d{2}\b", text))
        or bool(re.search(r"\bfrom\s+20\d{2}-\d{2}\s+to\s+20\d{2}-\d{2}\b", text))
    )
    if compare_like:
        month_keys = re.findall(r"\b20\d{2}-\d{2}\b", text)
        if len(month_keys) >= 2:
            return QuerySpec(
                task_type="compare_periods",
                metric="expenses",
                period_type="month_range",
                period_key=f"{month_keys[0]},{month_keys[1]}",
                scope=scope,
            )
        years = re.findall(r"\b20\d{2}\b", text)
        if len(years) >= 2:
            return QuerySpec(
                task_type="compare_periods",
                metric="expenses",
                period_type="year",
                period_key=f"{years[0]},{years[1]}",
                scope=scope,
            )

    has_top_category_phrase = any(
        token in text
        for token in (
            "top category",
            "highest category",
            "most category",
            "top spend category",
            "spend most on",
            "spent most on",
            "#1 spend category",
        )
    )
    has_category_rank_pattern = bool(
        re.search(
            r"\b(highest|top|biggest|largest|most)\b.*\b(category|categories)\b",
            text,
        )
    ) or bool(
        re.search(
            r"\b(category|categories)\b.*\b(highest|top|biggest|largest|most)\b",
            text,
        )
    )
    if has_top_category_phrase or has_category_rank_pattern:
        if "last month" in text:
            return QuerySpec(
                task_type="top_category_lookup",
                metric="top_category",
                period_type="month",
                period_key=previous_month_key(summary),
                scope=scope,
            )
        return QuerySpec(
            task_type="top_category_lookup",
            metric="top_category",
            period_type="unknown",
            period_key="",
            scope=scope,
        )

    has_recent_tx_phrase = any(
        token in text
        for token in (
            "recent transactions",
            "latest transactions",
            "recent activity",
            "latest activity",
            "latest tx",
            "recent tx",
            "recent purchases",
            "last few transactions",
        )
    )
    has_recent_spend_pattern = bool(re.search(r"\bwhat did i spend on recently\b", text)) or bool(
        re.search(r"\bshow my last few transactions\b", text)
    )
    if has_recent_tx_phrase or has_recent_spend_pattern:
        return QuerySpec(
            task_type="recent_transactions",
            metric="expenses",
            period_type="rolling_days",
            period_key="rolling_7d",
            scope=scope,
        )

    if ("this month" in text or "current month" in text) and (
        "spending" in text or "expenses" in text
    ):
        return QuerySpec(
            task_type="amount_lookup",
            metric="expenses",
            period_type="month",
            period_key=selected_month_key(summary),
            scope=scope,
        )
    if "last year" in text and ("spending" in text or "expenses" in text):
        return QuerySpec(
            task_type="amount_lookup",
            metric="expenses",
            period_type="year",
            period_key=str(
                int((summary or {}).get("time_anchor", {}).get("selected_year", 0) or 0) - 1
            )
            if isinstance(summary, dict)
            else "",
            scope=scope,
        )

    return QuerySpec()
