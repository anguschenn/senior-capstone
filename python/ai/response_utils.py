"""Response formatting helpers shared by API routes."""

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
