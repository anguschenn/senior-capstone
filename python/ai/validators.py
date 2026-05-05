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
        "version": max(1, min(int(to_float(summary.get("version", 1), 1)), 9)),
        "scope": clamp_str(summary.get("scope", ""), 32),
        "scope_label": clamp_str(summary.get("scope_label", ""), 64),
        "generated_at": clamp_str(summary.get("generated_at", ""), 40),
        "window_days": max(1, min(int(to_float(summary.get("window_days", 30), 30)), 365)),
    }

    time_anchor = summary.get("time_anchor")
    if isinstance(time_anchor, dict):
        cleaned["time_anchor"] = {
            "selected_month": clamp_str(time_anchor.get("selected_month", ""), 16),
            "selected_year": max(2000, min(2100, int(to_float(time_anchor.get("selected_year", 2026), 2026)))),
            "selected_month_expenses": max(0.0, to_float(time_anchor.get("selected_month_expenses", 0))),
            "selected_month_income": max(0.0, to_float(time_anchor.get("selected_month_income", 0))),
            "tz": clamp_str(time_anchor.get("tz", ""), 64),
        }

    windows = summary.get("windows")
    if isinstance(windows, dict):
        cleaned_windows = {}
        for key in ("last_7d", "last_30d", "last_90d"):
            item = windows.get(key)
            if not isinstance(item, dict):
                continue
            cleaned_windows[key] = {
                "income": max(0.0, to_float(item.get("income", 0))),
                "expenses": max(0.0, to_float(item.get("expenses", 0))),
                "tx_count": max(0, int(to_float(item.get("tx_count", 0)))),
            }
            if key == "last_30d":
                cleaned_windows[key]["expense_tx_count"] = max(
                    0, int(to_float(item.get("expense_tx_count", 0)))
                )
        if cleaned_windows:
            cleaned["windows"] = cleaned_windows

    year_index = summary.get("year_index")
    if isinstance(year_index, dict):
        cleaned_year_index = {}
        for year_key, item in list(year_index.items())[:10]:
            year_text = clamp_str(year_key, 8)
            if not year_text or not isinstance(item, dict):
                continue
            cleaned_year_index[year_text] = {
                "income": max(0.0, to_float(item.get("income", 0))),
                "expenses": max(0.0, to_float(item.get("expenses", 0))),
                "tx_count": max(0, int(to_float(item.get("tx_count", 0)))),
            }
        if cleaned_year_index:
            cleaned["year_index"] = cleaned_year_index

    month_index = summary.get("month_index")
    if isinstance(month_index, dict):
        cleaned_month_index = {}
        for month_key, item in list(month_index.items())[:48]:
            month_text = clamp_str(month_key, 16)
            if not month_text or not isinstance(item, dict):
                continue
            top_category = item.get("top_category")
            cleaned_top = None
            if isinstance(top_category, dict):
                top_name = clamp_str(top_category.get("name", ""), 64)
                if top_name:
                    cleaned_top = {
                        "name": top_name,
                        "amount": max(0.0, to_float(top_category.get("amount", 0))),
                    }
            cleaned_month_index[month_text] = {
                "income": max(0.0, to_float(item.get("income", 0))),
                "expenses": max(0.0, to_float(item.get("expenses", 0))),
                "tx_count": max(0, int(to_float(item.get("tx_count", 0)))),
                "expense_tx_count": max(0, int(to_float(item.get("expense_tx_count", 0)))),
                "top_category": cleaned_top,
            }
        if cleaned_month_index:
            cleaned["month_index"] = cleaned_month_index

    day_index_recent = summary.get("day_index_recent")
    if isinstance(day_index_recent, dict):
        cleaned_day_index = {}
        for day_key, item in list(day_index_recent.items())[:180]:
            day_text = clamp_str(day_key, 16)
            if not day_text or not isinstance(item, dict):
                continue
            cleaned_day_index[day_text] = {
                "income": max(0.0, to_float(item.get("income", 0))),
                "expenses": max(0.0, to_float(item.get("expenses", 0))),
                "tx_count": max(0, int(to_float(item.get("tx_count", 0)))),
            }
        if cleaned_day_index:
            cleaned["day_index_recent"] = cleaned_day_index

    month_day_index = summary.get("month_day_index")
    if isinstance(month_day_index, dict):
        cleaned_month_day = {}
        for month_key, rows in list(month_day_index.items())[:12]:
            month_text = clamp_str(month_key, 16)
            if not month_text or not isinstance(rows, list):
                continue
            cleaned_rows = []
            for item in rows[:40]:
                if not isinstance(item, dict):
                    continue
                day_text = clamp_str(item.get("date", ""), 16)
                if not day_text:
                    continue
                cleaned_rows.append(
                    {
                        "date": day_text,
                        "income": max(0.0, to_float(item.get("income", 0))),
                        "expenses": max(0.0, to_float(item.get("expenses", 0))),
                        "tx_count": max(0, int(to_float(item.get("tx_count", 0)))),
                    }
                )
            if cleaned_rows:
                cleaned_month_day[month_text] = cleaned_rows
        if cleaned_month_day:
            cleaned["month_day_index"] = cleaned_month_day

    rankings = summary.get("rankings")
    if isinstance(rankings, dict):
        highest_spending_months = rankings.get("highest_spending_months")
        highest_spending_days_recent = rankings.get("highest_spending_days_recent")
        cleaned_rankings = {}
        if isinstance(highest_spending_months, list):
            cleaned_rankings["highest_spending_months"] = [
                {
                    "month": clamp_str(item.get("month", ""), 16),
                    "expenses": max(0.0, to_float(item.get("expenses", 0))),
                }
                for item in highest_spending_months[:24]
                if isinstance(item, dict) and clamp_str(item.get("month", ""), 16)
            ]
        if isinstance(highest_spending_days_recent, list):
            cleaned_rankings["highest_spending_days_recent"] = [
                {
                    "date": clamp_str(item.get("date", ""), 16),
                    "expenses": max(0.0, to_float(item.get("expenses", 0))),
                }
                for item in highest_spending_days_recent[:40]
                if isinstance(item, dict) and clamp_str(item.get("date", ""), 16)
            ]
        if cleaned_rankings:
            cleaned["rankings"] = cleaned_rankings

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
        monthly_expense_ranking = annual.get("monthly_expense_ranking") if isinstance(annual.get("monthly_expense_ranking"), list) else []
        monthly_expense_trend = annual.get("monthly_expense_trend") if isinstance(annual.get("monthly_expense_trend"), list) else []
        monthly_top_categories = annual.get("monthly_top_categories") if isinstance(annual.get("monthly_top_categories"), list) else []
        daily_expense_totals = annual.get("daily_expense_totals") if isinstance(annual.get("daily_expense_totals"), list) else []
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
            "monthly_expense_ranking": [
                {
                    "month": clamp_str(item.get("month", ""), 16),
                    "expenses": max(0.0, to_float(item.get("expenses", 0))),
                }
                for item in monthly_expense_ranking[:24]
                if isinstance(item, dict) and clamp_str(item.get("month", ""), 16)
            ],
            "monthly_expense_trend": [
                {
                    "month": clamp_str(item.get("month", ""), 16),
                    "expenses": max(0.0, to_float(item.get("expenses", 0))),
                    "mom_change_pct": to_float(item.get("mom_change_pct", 0)),
                }
                for item in monthly_expense_trend[:24]
                if isinstance(item, dict) and clamp_str(item.get("month", ""), 16)
            ],
            "monthly_top_categories": [
                {
                    "month": clamp_str(item.get("month", ""), 16),
                    "category": clamp_str(item.get("category", ""), 64),
                    "amount": max(0.0, to_float(item.get("amount", 0))),
                }
                for item in monthly_top_categories[:24]
                if isinstance(item, dict)
                and clamp_str(item.get("month", ""), 16)
                and clamp_str(item.get("category", ""), 64)
            ],
            "daily_expense_totals": [
                {
                    "date": clamp_str(item.get("date", ""), 16),
                    "amount": max(0.0, to_float(item.get("amount", 0))),
                }
                for item in daily_expense_totals[:400]
                if isinstance(item, dict) and clamp_str(item.get("date", ""), 16)
            ],
        }

    if not any(
        (
            cleaned.get("totals"),
            cleaned.get("top_expense_categories"),
            cleaned.get("recent_transactions"),
            cleaned.get("annual_summary"),
            cleaned.get("month_index"),
            cleaned.get("day_index_recent"),
            cleaned.get("year_index"),
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
