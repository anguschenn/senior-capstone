"""Server-owned derived state, rebuilt after every bank sync (migrations 014 and 015).

  category_month_stats  spend per month and budget bucket, every month on file
  budgets               a new month's rows, when the previous month has rows and the app
                        hasn't opened the new month yet (limits from auto_limits)
  budget_alerts         this month's at-risk budget cards (same thresholds as the app), and
                        month-end over-budget results for finished months (alert history)
  budget_suggestions    for an alerted card whose limit is below the user's normal spending,
                        a suggestion to raise it to that normal, pending the user's decision

Everything uses budget_progress.py's rules, so it agrees with the Budget page. auto_limits()
is mirrored by BudgetService.autoLimits in Dart (tests/data/budget_auto_limit_contract.json
is run by both). The pure functions take rows and return rows; refresh_user_model() does the
database work and never raises, so a missing table or column only skips that piece.
"""

import calendar
import datetime as dt
import math

from budget_progress import (
    Decided,
    build_budget_progress,
    classify_rows,
    fetch_decisions,
    fetch_hidden_account_ids,
    normalize_category_key,
    row_id,
    signed_spend,
    without_hidden_accounts,
)
from supabase_repo import supabase

_PAGE_SIZE = 1000
TX_COLUMNS = (
    "plaid_transaction_id,plaid_account_id,amount,date,name,merchant_name,category,"
    "pfc_primary,pfc_detailed,pfc_confidence,pending"
)

# BudgetCategoryProgress.isBurnRateApproaching: projected >= 90% of the limit.
APPROACHING_RATIO = 0.9
# History-based limits: months looked back over, the fewest with spending needed, and the
# rounding step. Suggestions also need the change to clear both minimums.
HISTORY_MONTHS = 6
HISTORY_MIN_MONTHS = 3
ROUND_TO = 5.0
SUGGESTION_MIN_CHANGE = 10.0
SUGGESTION_MIN_CHANGE_RATIO = 0.10
# Finished months whose month-end results the backfill writes as alert history.
ALERT_HISTORY_MONTHS = 12


def _month_key(day: dt.date) -> str:
    return f"{day.year}-{day.month:02d}"


def previous_months(month: str, count: int) -> list[str]:
    """The `count` months before `month` ('YYYY-MM'), oldest first."""
    year, mon = (int(part) for part in month.split("-"))
    months = []
    for _ in range(count):
        mon -= 1
        if mon == 0:
            year, mon = year - 1, 12
        months.append(f"{year}-{mon:02d}")
    return list(reversed(months))


def previous_month(month: str) -> str:
    return previous_months(month, 1)[0]


# ── category_month_stats ────────────────────────────────────────────────


def build_category_month_stats(
    tx_rows: list[dict],
    rules: dict[str, str],
    *,
    kinds: dict[str, Decided] | None = None,
) -> list[dict]:
    """Spend and count per (month, bucket). Buckets are the raw budget_bucket_for_row names,
    before the Budget page folds unbudgeted ones into "Other". kinds is
    classify_rows(tx_rows, rules, decisions=...) when the caller already has it."""
    totals: dict[tuple[str, str], list] = {}
    if kinds is None:
        kinds = classify_rows(tx_rows, rules)
    for row in tx_rows:
        month = str(row.get("date") or "")[:7]
        if len(month) != 7:
            continue
        kind, bucket, paid_back, _ = kinds[row_id(row)]
        amount = signed_spend(kind, float(row["amount"]), paid_back)
        if amount == 0:
            continue
        bucket = bucket[:64] or "Other"
        entry = totals.setdefault((month, bucket), [0.0, 0])
        entry[0] += amount
        if kind == "spend":
            entry[1] += 1
    # A refund can outweigh a month's purchases in its bucket; spending never goes below 0.
    return [
        {"month": month, "category": bucket, "spent": round(max(spent, 0.0), 2), "tx_count": count}
        for (month, bucket), (spent, count) in sorted(totals.items())
        if spent > 0 or count
    ]


# ── History-based limits (mirrored in Dart: BudgetService.autoLimits) ───


def trimmed_mean(values: list[float]) -> float:
    """Mean after dropping the single highest and lowest value (3+ values)."""
    ordered = sorted(values)
    if len(ordered) >= 3:
        ordered = ordered[1:-1]
    return sum(ordered) / len(ordered) if ordered else 0.0


def _round_to(value: float, step: float) -> float:
    return float(math.floor(value / step + 0.5) * step)


def card_history(stats: list[dict], card_names: list[str], month: str) -> dict:
    """{'months': [...], 'spend': {card_key: [spend per month]}} for the HISTORY_MONTHS
    before `month` that have any spending. Buckets without a card of their own count toward
    "Other" when there is an Other card (BudgetService.cardKeyForBucket)."""
    card_keys = {normalize_category_key(n) for n in card_names}
    other = normalize_category_key("Other")
    with_spending = {s["month"] for s in stats if float(s.get("spent") or 0) > 0}
    months = [m for m in previous_months(month, HISTORY_MONTHS) if m in with_spending]
    totals: dict[tuple[str, str], float] = {}
    for s in stats:
        if s["month"] not in months:
            continue
        key = normalize_category_key(str(s["category"]))
        if key not in card_keys and other in card_keys:
            key = other
        totals[(s["month"], key)] = totals.get((s["month"], key), 0.0) + float(s["spent"])
    return {
        "months": months,
        "spend": {key: [round(totals.get((m, key), 0.0), 2) for m in months] for key in card_keys},
    }


def history_limit(monthly_spend: list[float]) -> float | None:
    """The user's normal month for a card: trimmed mean rounded to $5, or None with fewer
    than HISTORY_MIN_MONTHS months of history."""
    if len(monthly_spend) < HISTORY_MIN_MONTHS:
        return None
    return _round_to(trimmed_mean(monthly_spend), ROUND_TO)


def auto_limits(
    stats: list[dict], card_names: list[str], previous: dict[str, dict], month: str
) -> dict[str, dict]:
    """Limits for a new month's rows: {card name: {'limit', 'source'}}.

    previous maps a normalized card name to last month's {'limit', 'source'}. A limit the
    user set is carried forward as is; otherwise the history-based limit; otherwise last
    month's limit; otherwise $0. Only a user limit stays 'user'."""
    history = card_history(stats, card_names, month)
    out = {}
    for name in card_names:
        key = normalize_category_key(name)
        prev = previous.get(key)
        if prev and prev.get("source") == "user":
            out[name] = {"limit": float(prev["limit"]), "source": "user"}
            continue
        limit = history_limit(history["spend"].get(key, []))
        if limit is not None and limit > 0:
            out[name] = {"limit": limit, "source": "auto"}
            continue
        out[name] = {"limit": float(prev["limit"]) if prev else 0.0, "source": "auto"}
    return out


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


def _alert_row(item: dict, kind: str, projected: float) -> dict:
    spent, limit = float(item["spent"]), float(item["limit"])
    return {
        "category_id": item["category_id"],
        "category": item["category"],
        "kind": kind,
        "spent": round(spent, 2),
        "limit_amount": round(limit, 2),
        "projected_month_end": round(projected, 2),
        "used_ratio": round(spent / limit, 4),
    }


def build_alerts(progress: list[dict], today: dt.date) -> list[dict]:
    alerts = []
    for item in progress:
        found = alert_kind(float(item["spent"]), float(item["limit"]), today)
        if found:
            alerts.append(_alert_row(item, *found))
    return alerts


def build_month_end_alerts(progress: list[dict]) -> list[dict]:
    """A finished month has no pace left to project: only over or under the limit."""
    return [
        _alert_row(item, "over_budget", float(item["spent"]))
        for item in progress
        if float(item["limit"]) > 0 and float(item["spent"]) > float(item["limit"])
    ]


# ── budget_suggestions ──────────────────────────────────────────────────


def build_suggestions(
    budget_rows: list[dict],
    category_names_by_id: dict[str, str],
    stats: list[dict],
    month: str,
    alerts: list[dict],
    past_limits: dict[str, dict[str, float]] | None = None,
) -> list[dict]:
    """Only for cards with an alert this month whose limit is below the user's normal month
    (history_limit): suggest raising it to that normal. Spending above one's own normal gets
    the alert alone. past_limits ({month: {card_key: limit}}) feeds months_over, the number
    of history months the card ended over its limit."""
    alerted = {str(a["category_id"]) for a in alerts}
    names = [category_names_by_id.get(str(r.get("category_id") or ""), "") for r in budget_rows]
    history = card_history(stats, [n for n in names if n], month)
    past_limits = past_limits or {}
    suggestions = []
    for row, name in zip(budget_rows, names):
        budget_id = str(row.get("id") or "").strip()
        category_id = str(row.get("category_id") or "").strip()
        if not budget_id or category_id not in alerted or not name:
            continue
        key = normalize_category_key(name)
        spend = history["spend"].get(key, [])
        suggested = history_limit(spend)
        current = float(row.get("monthly_limit") or 0)
        if suggested is None or suggested <= current:
            continue
        change = suggested - current
        if change < SUGGESTION_MIN_CHANGE or (
            current > 0 and change < current * SUGGESTION_MIN_CHANGE_RATIO
        ):
            continue
        months_over = sum(
            1
            for m, spent in zip(history["months"], spend)
            if 0 < past_limits.get(m, {}).get(key, 0) < spent
        )
        suggestions.append(
            {
                "budget_id": budget_id,
                "category_id": category_id,
                "category": name,
                "month": month,
                "current_limit": round(current, 2),
                "suggested_limit": suggested,
                "basis": {
                    "method": "trimmed_mean",
                    "months": history["months"],
                    "monthly_spend": spend,
                    "months_over": months_over,
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
            # A hidden account counts as never linked, everywhere the backend looks.
            return without_hidden_accounts(rows, fetch_hidden_account_ids(user_id, supabase))
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
    """Budget rows for a month; limit_source is 'user' when migration 015 isn't applied."""
    try:
        return (
            supabase.table("budgets")
            .select("id,category_id,monthly_limit,limit_source")
            .eq("user_id", user_id)
            .eq("month_year", month)
            .execute()
        ).data or []
    except Exception:
        rows = (
            supabase.table("budgets")
            .select("id,category_id,monthly_limit")
            .eq("user_id", user_id)
            .eq("month_year", month)
            .execute()
        ).data or []
        return [{**r, "limit_source": "user"} for r in rows]


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


def ensure_month_budget_rows(
    user_id: str, month: str, stats: list[dict], names: dict[str, str]
) -> list[dict]:
    """Create `month`'s budget rows from the previous month's cards when the app hasn't yet,
    with auto_limits. Never overwrites a row (the app may have created it first). Returns
    the month's rows."""
    existing = fetch_budget_rows(user_id, month)
    if existing:
        return existing
    previous_rows = fetch_budget_rows(user_id, previous_month(month))
    if not previous_rows:
        return []  # nothing to base the cards on; the app creates them when it opens
    by_name = {
        names.get(str(r["category_id"]), ""): r for r in previous_rows if r.get("category_id")
    }
    by_name.pop("", None)
    previous = {
        normalize_category_key(name): {
            "limit": float(r.get("monthly_limit") or 0),
            "source": r.get("limit_source") or "user",
        }
        for name, r in by_name.items()
    }
    limits = auto_limits(stats, list(by_name), previous, month)
    rows = [
        {
            "user_id": user_id,
            "category_id": by_name[name]["category_id"],
            "month_year": month,
            "monthly_limit": value["limit"],
            "rollover_amount": 0,
            "limit_source": value["source"],
        }
        for name, value in limits.items()
    ]
    supabase.table("budgets").upsert(
        rows, on_conflict="user_id,category_id,month_year", ignore_duplicates=True
    ).execute()
    return fetch_budget_rows(user_id, month)


def write_alerts(user_id: str, month: str, alerts: list[dict], historical: bool = False) -> None:
    """historical: a finished month's results. They are history, not news, so they are
    marked as already notified and never reach a future push sender."""
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
            row.update({"dismissed_at": None, "notified_at": now if historical else None})
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


def finalize_month_alerts(
    user_id: str,
    month: str,
    tx_rows: list[dict],
    rules: dict[str, str],
    names: dict[str, str],
    *,
    kinds: dict[str, Decided] | None = None,
) -> int | None:
    """Write a finished month's month-end result as alert history. None when the month has
    no budget rows (never opened in the app)."""
    budget_rows = fetch_budget_rows(user_id, month)
    if not budget_rows:
        return None
    alerts = build_month_end_alerts(
        build_budget_progress(budget_rows, names, tx_rows, rules, month, kinds=kinds)
    )
    write_alerts(user_id, month, alerts, historical=True)
    return len(alerts)


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


def past_limits_by_month(user_id: str, months: list[str], names: dict[str, str]) -> dict:
    out = {}
    for month in months:
        out[month] = {
            normalize_category_key(names.get(str(r.get("category_id")), "")): float(
                r.get("monthly_limit") or 0
            )
            for r in fetch_budget_rows(user_id, month)
        }
    return out


def refresh_user_model(user_id: str, today: dt.date | None = None, history_months: int = 1) -> dict:
    """Rebuild stats, this month's rows, alerts and suggestions for one user, and finalize
    the last `history_months` finished months' alert history. Never raises. Returns the
    transaction rows read (so the caller can reuse them) and what was written."""
    today = today or dt.date.today()
    month = _month_key(today)
    result = {"tx_rows": [], "stats": None, "alerts": None, "suggestions": None, "history": None}
    try:
        tx_rows = fetch_all_transactions(user_id)
        rules = fetch_rules(user_id)
        names = fetch_category_names(user_id)
        decisions = fetch_decisions(user_id)
    except Exception as error:
        print(f"user model skipped for user {user_id}: {type(error).__name__}")
        return result
    result["tx_rows"] = tx_rows
    # Classify once: stats, last month's history and this month's progress all read the
    # same rows with the same rules.
    kinds = classify_rows(tx_rows, rules, decisions=decisions)
    stats = build_category_month_stats(tx_rows, rules, kinds=kinds)

    try:
        write_category_month_stats(user_id, stats)
        result["stats"] = len(stats)
    except Exception as error:
        print(f"category_month_stats skipped for user {user_id}: {type(error).__name__}")

    try:
        history = {}
        for past in previous_months(month, history_months):
            written = finalize_month_alerts(user_id, past, tx_rows, rules, names, kinds=kinds)
            if written is not None:
                history[past] = written
        result["history"] = history
    except Exception as error:
        print(f"alert history skipped for user {user_id}: {type(error).__name__}")

    try:
        budget_rows = ensure_month_budget_rows(user_id, month, stats, names)
    except Exception as error:
        print(f"budget rows skipped for user {user_id}: {type(error).__name__}")
        return result
    if not budget_rows:
        return result

    alerts = []
    try:
        progress = build_budget_progress(budget_rows, names, tx_rows, rules, month, kinds=kinds)
        alerts = build_alerts(progress, today)
        write_alerts(user_id, month, alerts)
        result["alerts"] = len(alerts)
    except Exception as error:
        print(f"budget_alerts skipped for user {user_id}: {type(error).__name__}")

    try:
        past = past_limits_by_month(user_id, previous_months(month, HISTORY_MONTHS), names)
        suggestions = build_suggestions(budget_rows, names, stats, month, alerts, past)
        write_suggestions(user_id, month, suggestions)
        result["suggestions"] = len(suggestions)
    except Exception as error:
        print(f"budget_suggestions skipped for user {user_id}: {type(error).__name__}")
    return result
