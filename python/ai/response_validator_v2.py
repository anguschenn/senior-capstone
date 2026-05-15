"""V2 response validator for deterministic outputs."""

import re


def validate_v2_response(plan, query_spec, raw_result):
    """Return sanitized deterministic result or None when invalid."""
    if not isinstance(raw_result, dict):
        return None
    reply = str(raw_result.get("reply", "") or "").strip()
    if not reply:
        return None

    validated = dict(raw_result)
    validated.setdefault("insights", [])
    validated.setdefault("actions", [])
    validated.setdefault("missing_fields", [])
    validated.setdefault("facts_used", [])
    validated.setdefault("period_resolved", "")

    # Guardrail: for spending-change op, avoid extra month references beyond target+previous.
    if getattr(plan, "operation", "") == "spending_change_month_over_month":
        target = getattr(query_spec, "period_key", "") or ""
        if re.match(r"^20\d{2}-\d{2}$", target):
            y, m = target.split("-")
            yi = int(y)
            mi = int(m)
            prev = f"{yi - 1}-12" if mi == 1 else f"{yi}-{mi - 1:02d}"
            months_in_reply = set(re.findall(r"\b20\d{2}-\d{2}\b", reply))
            allowed = {target, prev}
            if any(month not in allowed for month in months_in_reply):
                return None

    return validated
