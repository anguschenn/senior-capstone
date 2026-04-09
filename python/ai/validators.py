import time
from collections import defaultdict, deque


def clamp_str(value, max_len):
    if not isinstance(value, str):
        return ""
    return value.strip()[:max_len]


def to_float(value, default=0.0):
    try:
        if isinstance(value, (int, float)):
            return float(value)
        return float(str(value))
    except Exception:
        return default


def sanitize_history(history, max_turns=6):
    if not isinstance(history, list):
        return []
    cleaned = []
    for item in history[-max_turns:]:
        if not isinstance(item, dict):
            continue
        role = clamp_str(item.get("role", ""), 16).lower()
        if role not in ("user", "assistant", "system"):
            continue
        text = clamp_str(item.get("text", ""), 1200)
        if not text:
            continue
        cleaned.append({"role": role, "text": text})
    return cleaned


def sanitize_budget_progress(progress, max_items=20):
    if not isinstance(progress, list):
        return []
    cleaned = []
    for item in progress[:max_items]:
        if not isinstance(item, dict):
            continue
        category = clamp_str(item.get("category", ""), 64)
        if not category:
            continue
        spent = max(0.0, to_float(item.get("spent", 0)))
        limit_value = max(0.0, to_float(item.get("limit", 0)))
        ratio = max(0.0, to_float(item.get("ratio", 0)))
        cleaned.append(
            {
                "category": category,
                "spent": spent,
                "limit": limit_value,
                "ratio": ratio,
            }
        )
    return cleaned


def sanitize_subscriptions(subscriptions, max_items=20):
    if not isinstance(subscriptions, list):
        return []
    cleaned = []
    for item in subscriptions[:max_items]:
        if not isinstance(item, dict):
            continue
        name = clamp_str(item.get("name", "") or item.get("merchant", ""), 80)
        if not name:
            continue
        amount = max(0.0, to_float(item.get("amount", 0)))
        frequency = clamp_str(item.get("frequency", "monthly"), 16).lower() or "monthly"
        cleaned.append({"name": name, "amount": amount, "frequency": frequency})
    return cleaned


def sanitize_savings_goal(goal):
    if not isinstance(goal, dict):
        return {}
    return {
        "target_amount": max(0.0, to_float(goal.get("target_amount", 0))),
        "current_savings": max(0.0, to_float(goal.get("current_savings", 0))),
        "monthly_contribution": max(0.0, to_float(goal.get("monthly_contribution", 0))),
        "target_date": clamp_str(goal.get("target_date", ""), 20),
    }


def sanitize_spending_summary(summary):
    if not isinstance(summary, dict):
        return None

    cleaned = {
        "scope": clamp_str(summary.get("scope", ""), 32),
        "generated_at": clamp_str(summary.get("generated_at", ""), 40),
        "window_days": max(1, min(int(to_float(summary.get("window_days", 30), 30)), 365)),
    }

    totals = summary.get("totals")
    if isinstance(totals, dict):
        cleaned["totals"] = {
            "income_30d": max(0.0, to_float(totals.get("income_30d", 0))),
            "expenses_30d": max(0.0, to_float(totals.get("expenses_30d", 0))),
            "net_30d": to_float(totals.get("net_30d", 0)),
            "tx_count_30d": max(0, int(to_float(totals.get("tx_count_30d", 0)))),
            "expense_tx_count_30d": max(
                0, int(to_float(totals.get("expense_tx_count_30d", 0)))
            ),
            "income_month": max(0.0, to_float(totals.get("income_month", 0))),
            "expenses_month": max(0.0, to_float(totals.get("expenses_month", 0))),
            "net_month": to_float(totals.get("net_month", 0)),
        }

    top_categories = []
    raw_categories = summary.get("top_expense_categories")
    if isinstance(raw_categories, list):
        for item in raw_categories[:10]:
            if not isinstance(item, dict):
                continue
            category = clamp_str(item.get("category", ""), 64)
            if not category:
                continue
            top_categories.append(
                {
                    "category": category,
                    "amount": max(0.0, to_float(item.get("amount", 0))),
                }
            )
    cleaned["top_expense_categories"] = top_categories

    recent = []
    raw_recent = summary.get("recent_transactions")
    if isinstance(raw_recent, list):
        for item in raw_recent[:8]:
            if not isinstance(item, dict):
                continue
            name = clamp_str(item.get("name", ""), 80)
            if not name:
                continue
            recent.append(
                {
                    "date": clamp_str(item.get("date", ""), 16),
                    "name": name,
                    "category": clamp_str(item.get("category", ""), 64),
                    "amount": to_float(item.get("amount", 0)),
                }
            )
    cleaned["recent_transactions"] = recent

    annual = summary.get("annual_summary")
    if isinstance(annual, dict):
        annual_totals = annual.get("totals") if isinstance(annual.get("totals"), dict) else {}
        monthly = annual.get("monthly_breakdown") if isinstance(annual.get("monthly_breakdown"), list) else []
        categories_year = annual.get("top_expense_categories_year") if isinstance(annual.get("top_expense_categories_year"), list) else []
        cleaned["annual_summary"] = {
            "year": max(2000, min(2100, int(to_float(annual.get("year", 2026), 2026)))),
            "totals": {
                "income_year": max(0.0, to_float(annual_totals.get("income_year", 0))),
                "expenses_year": max(0.0, to_float(annual_totals.get("expenses_year", 0))),
                "net_year": to_float(annual_totals.get("net_year", 0)),
                "expense_tx_count_year": max(
                    0, int(to_float(annual_totals.get("expense_tx_count_year", 0)))
                ),
            },
            "monthly_breakdown": [
                {
                    "month": clamp_str(item.get("month", ""), 16),
                    "income": max(0.0, to_float(item.get("income", 0))),
                    "expenses": max(0.0, to_float(item.get("expenses", 0))),
                }
                for item in monthly[:12]
                if isinstance(item, dict) and clamp_str(item.get("month", ""), 16)
            ],
            "top_expense_categories_year": [
                {
                    "category": clamp_str(item.get("category", ""), 64),
                    "amount": max(0.0, to_float(item.get("amount", 0))),
                }
                for item in categories_year[:10]
                if isinstance(item, dict) and clamp_str(item.get("category", ""), 64)
            ],
        }

    if not any(
        (
            cleaned.get("totals"),
            cleaned.get("top_expense_categories"),
            cleaned.get("recent_transactions"),
            cleaned.get("annual_summary"),
        )
    ):
        return None
    return cleaned


class SimpleRateLimiter:
    def __init__(self, max_requests=30, window_seconds=60):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self._events = defaultdict(deque)

    def allow(self, key):
        now = time.time()
        bucket = self._events[key]
        cutoff = now - self.window_seconds
        while bucket and bucket[0] < cutoff:
            bucket.popleft()
        if len(bucket) >= self.max_requests:
            return False
        bucket.append(now)
        return True

