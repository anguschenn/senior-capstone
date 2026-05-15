"""Single source of truth for selected-time and relative-period resolution."""

import re
from datetime import date as date_cls
from typing import Optional


def selected_month_key(summary: Optional[dict]) -> str:
    """Resolve selected month from summary.time_anchor with safe fallback."""
    if isinstance(summary, dict):
        time_anchor = summary.get("time_anchor")
        if isinstance(time_anchor, dict):
            selected = str(time_anchor.get("selected_month", "") or "").strip()
            if re.match(r"^20\d{2}-\d{2}$", selected):
                return selected
    return date_cls.today().strftime("%Y-%m")


def previous_month_from_anchor(anchor_month_key: str) -> str:
    """Resolve previous month key from an explicit YYYY-MM anchor."""
    if not re.match(r"^20\d{2}-\d{2}$", anchor_month_key or ""):
        return ""
    year_s, month_s = anchor_month_key.split("-")
    year = int(year_s)
    month = int(month_s)
    if month == 1:
        return f"{year - 1}-12"
    return f"{year}-{month - 1:02d}"


def previous_month_key(summary: Optional[dict]) -> str:
    """Resolve previous month relative to selected month when available."""
    selected = selected_month_key(summary)
    return previous_month_from_anchor(selected)
