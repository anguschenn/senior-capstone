"""Server-owned derived state, rebuilt after every bank sync (migration 014).

  category_month_stats  spend per month and budget bucket, every month on file
  budget_alerts         this month's at-risk budget cards (same thresholds as the app)
  budget_suggestions    a suggested monthly limit per card, pending the user's decision

All three use budget_progress.py's rules, so they agree with the Budget page. The pure
functions take rows and return rows; refresh_user_model() does the database work and never
raises, so a missing table (014 not applied yet) only skips that piece.
"""

import calendar
import datetime as dt
import math

from budget_progress import (
    budget_bucket_for_row,
    build_budget_progress,
    counts_as_spending,
)
from supabase_repo import supabase

_PAGE_SIZE = 1000
TX_COLUMNS = (
    "plaid_transaction_id,plaid_account_id,amount,date,name,merchant_name,category,"
    "pfc_primary,pfc_detailed,pfc_confidence,pending"
)

# BudgetCategoryProgress.isBurnRateApproaching: projected >= 90% of the limit.
APPROACHING_RATIO = 0.9
# Suggestions: months of history, the least of them needed, and the smallest change
# worth asking the user about (both must hold).
SUGGESTION_MONTHS = 6
SUGGESTION_MIN_MONTHS = 3
SUGGESTION_MIN_CHANGE = 10.0
SUGGESTION_MIN_CHANGE_RATIO = 0.10
SUGGESTION_ROUND_TO = 5.0


def _month_key(day: dt.date) -> str:
    return f"{day.year}-{day.month:02d}"


def _previous_months(month: str, count: int) -> list[str]:
    """The `count` months before `month` ('YYYY-MM'), oldest first."""
    year, mon = (int(part) for part in month.split("-"))
    months = []
    for _ in range(count):
        mon -= 1
        if mon == 0:
            year, mon = year - 1, 12
        months.append(f"{year}-{mon:02d}")
    return list(reversed(months))


# ── category_month_stats ────────────────────────────────────────────────


def build_category_month_stats(tx_rows: list[dict], rules: dict[str, str]) -> list[dict]:
    """Spend and count per (month, bucket). Buckets are the raw budget_bucket_for_row names,
    before the Budget page folds unbudgeted ones into "Other"."""
    totals: dict[tuple[str, str], list] = {}
    for row in tx_rows:
        month = str(row.get("date") or "")[:7]
        if len(month) != 7 or not counts_as_spending(row):
            continue
        bucket = budget_bucket_for_row(row, rules)[:64] or "Other"
        entry = totals.setdefault((month, bucket), [0.0, 0])
        entry[0] += abs(float(row["amount"]))
        entry[1] += 1
    return [
        {"month": month, "category": bucket, "spent": round(spent, 2), "tx_count": count}
        for (month, bucket), (spent, count) in sorted(totals.items())
    ]


# ── budget_alerts ───────────────────────────────────────────────────────


def alert_kind(spent: float, limit: float, today: dt.date) -> tuple[str, float] | None:
    """(kind, projected_month_end) for a current-month card, or None when it isn't at risk.
    Mirrors BudgetCategoryProgress: isOverBudget, isBurnRateHigh, isBurnRateApproaching."""
    if limit <= 0 or spent <= 0:
        return None
    days_in_month = calendar.monthrange(today.year, today.month)[1]
    elapsed = max(1, min(today.day, days_in_month))
    projected = spent / elapsed * days_in_month
    if spent > limit:
        return "over_budget", projected
    if projected > limit:
        return "projected_over", projected
    if projected >= limit * APPROACHING_RATIO:
        return "approaching", projected
    return None


def build_alerts(progress: list[dict], today: dt.date) -> list[dict]:
    alerts = []
    for item in progress:
        spent, limit = float(item["spent"]), float(item["limit"])
        found = alert_kind(spent, limit, today)
        if not found:
            continue
        kind, projected = found
        alerts.append(
            {
                "category_id": item["category_id"],
                "category": item["category"],
                "kind": kind,
                "spent": round(spent, 2),
                "limit_amount": round(limit, 2),
                "projected_month_end": round(projected, 2),
                "used_ratio": round(spent / limit, 4),
            }
        )
    return alerts


# ── budget_suggestions ──────────────────────────────────────────────────


def trimmed_mean(values: list[float]) -> float:
    """Mean after dropping the single highest and lowest value (3+ values)."""
    ordered = sorted(values)
    if len(ordered) >= 3:
        ordered = ordered[1:-1]
    return sum(ordered) / len(ordered) if ordered else 0.0


def _round_to(value: float, step: float) -> float:
    return float(math.floor(value / step + 0.5) * step)


def build_suggestions(
    budget_rows: list[dict],
    category_names_by_id: dict[str, str],
    tx_rows: list[dict],
    rules: dict[str, str],
    month: str,
) -> list[dict]:
    """A suggested limit per budget card for `month`, from the trimmed mean of the card's
    spend over the previous SUGGESTION_MONTHS months that have any transactions. Months use
    the Budget page's card totals (unbudgeted buckets folded into "Other")."""
    months_with_data = {str(r.get("date") or "")[:7] for r in tx_rows}
    history = [m for m in _previous_months(month, SUGGESTION_MONTHS) if m in months_with_data]
    if len(history) < SUGGESTION_MIN_MONTHS:
        return []
    spent_by_month = {
        m: {
            item["budget_id"]: float(item["spent"])
            for item in build_budget_progress(budget_rows, category_names_by_id, tx_rows, rules, m)
        }
        for m in history
    }
    suggestions = []
    for row in budget_rows:
        budget_id = str(row.get("id") or "").strip()
        category_id = str(row.get("category_id") or "").strip()
        if not budget_id or not category_id:
            continue
        current = float(row.get("monthly_limit") or 0)
        values = [spent_by_month[m].get(budget_id, 0.0) for m in history]
        suggested = _round_to(trimmed_mean(values), SUGGESTION_ROUND_TO)
        change = abs(suggested - current)
        # $0 means no spending on record: nothing to base a limit on, so don't ask.
        if (
            suggested <= 0
            or change < SUGGESTION_MIN_CHANGE
            or (current > 0 and change < current * SUGGESTION_MIN_CHANGE_RATIO)
        ):
            continue
        suggestions.append(
            {
                "budget_id": budget_id,
                "category_id": category_id,
                "category": category_names_by_id.get(category_id, "Unknown"),
                "month": month,
                "current_limit": round(current, 2),
                "suggested_limit": suggested,
                "basis": {
                    "method": "trimmed_mean",
                    "months": history,
                    "monthly_spend": [round(v, 2) for v in values],
                },
            }
        )
    return suggestions


# ── Database access ─────────────────────────────────────────────────────


def fetch_all_transactions(user_id: str) -> list[dict]:
    rows: list[dict] = []
    start = 0
    while True:
        page = (
            supabase.table("transactions")
            .select(TX_COLUMNS)
            .eq("user_id", user_id)
            .order("date", desc=True)
            .range(start, start + _PAGE_SIZE - 1)
            .execute()
        ).data or []
        rows.extend(page)
        if len(page) < _PAGE_SIZE:
            return rows
        start += _PAGE_SIZE


def fetch_rules(user_id: str) -> dict[str, str]:
    rows = (
        supabase.table("category_match_rules")
        .select("rule_key,category")
        .eq("user_id", user_id)
        .execute()
    ).data or []
    return {
        str(r.get("rule_key") or "").strip(): str(r.get("category") or "").strip() for r in rows
    }


def fetch_category_names(user_id: str) -> dict[str, str]:
    rows = (
        supabase.table("categories")
        .select("id,name")
        .or_(f"user_id.eq.{user_id},user_id.is.null")
        .execute()
    ).data or []
    return {str(c["id"]): str(c.get("name") or "") for c in rows}


def fetch_budget_rows(user_id: str, month: str) -> list[dict]:
    return (
        supabase.table("budgets")
        .select("id,category_id,monthly_limit")
        .eq("user_id", user_id)
        .eq("month_year", month)
        .execute()
    ).data or []


def _now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def write_category_month_stats(user_id: str, stats: list[dict]) -> None:
    now = _now_iso()
    rows = [{"user_id": user_id, "updated_at": now, **s} for s in stats]
    for start in range(0, len(rows), 500):
        supabase.table("category_month_stats").upsert(
            rows[start : start + 500], on_conflict="user_id,month,category"
        ).execute()
    # Buckets that no longer have spending (a transaction removed or recategorized).
    keep = {(s["month"], s["category"]) for s in stats}
    existing = (
        supabase.table("category_month_stats")
        .select("month,category")
        .eq("user_id", user_id)
        .execute()
    ).data or []
    for row in existing:
        if (row["month"], row["category"]) not in keep:
            supabase.table("category_month_stats").delete().eq("user_id", user_id).eq(
                "month", row["month"]
            ).eq("category", row["category"]).execute()


def write_alerts(user_id: str, month: str, alerts: list[dict]) -> None:
    now = _now_iso()
    existing = {
        str(r["category_id"]): r
        for r in (
            supabase.table("budget_alerts")
            .select("id,category_id,kind,resolved_at")
            .eq("user_id", user_id)
            .eq("month", month)
            .execute()
        ).data
        or []
    }
    for alert in alerts:
        row = {"user_id": user_id, "month": month, "updated_at": now, "resolved_at": None, **alert}
        previous = existing.pop(str(alert["category_id"]), None)
        if previous is None or previous.get("resolved_at") or previous.get("kind") != alert["kind"]:
            # New, re-opened or escalated: the user should see (and later be sent) it again.
            row.update({"dismissed_at": None, "notified_at": None})
            if previous is None or previous.get("resolved_at"):
                row["first_detected_at"] = now
        supabase.table("budget_alerts").upsert(
            row, on_conflict="user_id,month,category_id"
        ).execute()
    for previous in existing.values():
        if not previous.get("resolved_at"):
            supabase.table("budget_alerts").update({"resolved_at": now, "updated_at": now}).eq(
                "id", previous["id"]
            ).execute()


def write_suggestions(user_id: str, month: str, suggestions: list[dict]) -> None:
    now = _now_iso()
    existing = {
        str(r["category_id"]): r
        for r in (
            supabase.table("budget_suggestions")
            .select("id,category_id,status")
            .eq("user_id", user_id)
            .eq("month", month)
            .execute()
        ).data
        or []
    }
    for suggestion in suggestions:
        previous = existing.pop(str(suggestion["category_id"]), None)
        if previous and previous.get("status") != "pending":
            continue  # the user already decided; never re-ask for the same month
        supabase.table("budget_suggestions").upsert(
            {"user_id": user_id, "status": "pending", "updated_at": now, **suggestion},
            on_conflict="user_id,category_id,month",
        ).execute()
    # A pending suggestion that no longer holds (spending moved, limit changed) is withdrawn.
    for previous in existing.values():
        if previous.get("status") == "pending":
            supabase.table("budget_suggestions").delete().eq("id", previous["id"]).execute()


def refresh_user_model(user_id: str, today: dt.date | None = None) -> dict:
    """Rebuild stats, alerts and suggestions for one user. Never raises. Returns the
    transaction rows read (so the caller can reuse them) and what was written."""
    today = today or dt.date.today()
    month = _month_key(today)
    result = {"tx_rows": [], "stats": None, "alerts": None, "suggestions": None}
    try:
        tx_rows = fetch_all_transactions(user_id)
        rules = fetch_rules(user_id)
    except Exception as error:
        print(f"user model skipped for user {user_id}: {type(error).__name__}")
        return result
    result["tx_rows"] = tx_rows

    try:
        stats = build_category_month_stats(tx_rows, rules)
        write_category_month_stats(user_id, stats)
        result["stats"] = len(stats)
    except Exception as error:
        print(f"category_month_stats skipped for user {user_id}: {type(error).__name__}")

    try:
        budget_rows = fetch_budget_rows(user_id, month)
        names = fetch_category_names(user_id) if budget_rows else {}
    except Exception as error:
        print(f"budget read skipped for user {user_id}: {type(error).__name__}")
        return result
    if not budget_rows:
        return result  # the app creates a month's budget rows the first time it opens it

    try:
        progress = build_budget_progress(budget_rows, names, tx_rows, rules, month)
        alerts = build_alerts(progress, today)
        write_alerts(user_id, month, alerts)
        result["alerts"] = len(alerts)
    except Exception as error:
        print(f"budget_alerts skipped for user {user_id}: {type(error).__name__}")

    try:
        suggestions = build_suggestions(budget_rows, names, tx_rows, rules, month)
        write_suggestions(user_id, month, suggestions)
        result["suggestions"] = len(suggestions)
    except Exception as error:
        print(f"budget_suggestions skipped for user {user_id}: {type(error).__name__}")
    return result
