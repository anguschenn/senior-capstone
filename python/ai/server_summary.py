"""The chat's spending summary, built on the server from Supabase instead of sent by the app.

A port of AiSummaryService.build (ssdemo_1/lib/services/ai_summary_service.dart) together
with the parts of SyncService / FinancialSnapshotService that feed it:

  transactions  AppTransaction.fromMap, de-duplicated by Plaid id
  category      the Budget page bucket (remembered rule, else classify_by_pfc_signals),
                which is what SyncService puts in reviewedCategoryByTxId for every row
  budgets       budget_progress.build_budget_progress for the selected month and accounts
  totals.*_month  income/expenses of the visible transactions in the selected period

tests/data/ai_summary_contract.json is run by both tests/test_server_summary.py and
ssdemo_1/test/services/ai_summary_contract_test.dart. Change the rules on either side, add a
case there and make both pass, or the chat will answer differently from the screen.

Known differences from the app: the server reads every transaction (the app reads the
newest 1000), and it can't see category picks made in the open app but not yet confirmed.

Results are cached per user, accounts, month and day; sync_jobs.run_post_sync clears a
user's entries after each sync. Process-local, like the snapshot cache: one gunicorn worker.
"""

import datetime as dt
import re
import threading
import time

from budget_progress import (
    budget_bucket_for_row,
    build_budget_progress,
    classify_rows,
    is_credit_card_payment_row,
    row_kind,
    rule_key_for_row,
)

SUMMARY_VERSION = 3
_CACHE_TTL_SECONDS = 15 * 60
_cache: dict[tuple, tuple[float, dict]] = {}
_cache_lock = threading.Lock()
_MONTH_RE = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")
_YEAR_RE = re.compile(r"^\d{4}$")


# ── AppTransaction.fromMap ──────────────────────────────────────────────


def prettify_category_label(raw: str) -> str:
    """formatters.dart prettifyCategoryLabel."""
    cleaned = raw.strip()
    if not cleaned:
        return "Uncategorized"
    parts = [p for p in re.split(r"\s+", cleaned.replace("_", " ").lower()) if p]
    return " ".join(p[0].upper() + p[1:] for p in parts)


def _text(value) -> str | None:
    return value if isinstance(value, str) else None


def _parse_amount(raw) -> float:
    if isinstance(raw, (int, float)) and not isinstance(raw, bool):
        return float(raw)
    try:
        return float(str(raw))
    except ValueError:
        return 0.0


class Tx:
    """The fields of AppTransaction the summary reads."""

    __slots__ = (
        "id",
        "dedupe_key",
        "account_id",
        "name",
        "description",
        "transaction_type",
        "category",
        "primary_category",
        "date",
        "amount",
        "account_type",
        "raw_pfc_primary",
        "raw_pfc_detailed",
        "bucket",
        "kind",
    )

    def __init__(self, row: dict, account_meta: dict, rules: dict[str, str]):
        merchant = (_text(row.get("merchant_name")) or "").strip() or None
        fallback = (_text(row.get("name")) or "").strip() if _text(row.get("name")) else None
        description = fallback
        if fallback:
            self.name = fallback
        elif merchant:
            self.name = merchant
        else:
            self.name = description or "Unknown"
        detailed = _text(row.get("pfc_detailed"))
        if detailed is None:
            detailed = _text(row.get("category"))
        detailed = detailed.strip() if detailed is not None else None
        primary = (_text(row.get("pfc_primary")) or "").strip() if row.get("pfc_primary") else None
        if detailed:
            self.category = prettify_category_label(detailed)
        elif primary:
            self.category = prettify_category_label(primary)
        else:
            self.category = "Uncategorized"
        self.primary_category = prettify_category_label(primary) if primary else "Uncategorized"
        self.transaction_type = primary or ""
        self.description = description or ""
        self.raw_pfc_primary = primary or ""
        self.raw_pfc_detailed = detailed or ""
        raw_date = str(row.get("date") or "")[:10]
        try:
            self.date = dt.date.fromisoformat(raw_date)
        except ValueError:
            self.date = dt.date.today()
        self.amount = _parse_amount(row.get("amount"))
        self.account_id = str(row.get("plaid_account_id") or "").strip()
        meta = account_meta.get(self.account_id) or {}
        self.account_type = str(meta.get("account_type") or "").strip()
        provider_id = str(row.get("plaid_transaction_id") or "").strip()
        self.dedupe_key = provider_id or (
            f"{self.name.lower()}|{self.amount:.2f}|{self.date.isoformat()}"
        )
        self.id = provider_id or self.dedupe_key
        self.bucket = budget_bucket_for_row(row, rules)
        # build_transactions replaces this with the whole-list decision (refund matching).
        self.kind = row_kind(row, rules.get(rule_key_for_row(row), ""), self.account_type)

    # ── AppTransaction getters ──
    @property
    def is_expense(self) -> bool:
        return self.amount > 0

    @property
    def is_income(self) -> bool:
        return self.amount < 0

    @property
    def display_amount(self) -> float:
        return abs(self.amount)

    @property
    def is_credit_card_payment(self) -> bool:
        return is_credit_card_payment_row(
            {"pfc_detailed": self.raw_pfc_detailed, "pfc_primary": self.raw_pfc_primary}
        )

    @property
    def expense_amount(self) -> float:
        """Spending; negative for a refund. Own-account transfers count as nothing."""
        if self.kind == "spend":
            return self.display_amount
        if self.kind == "refund":
            return -self.display_amount
        return 0.0

    def _is_refund_like(self) -> bool:
        text = (
            f"{self.name.lower()} {self.description.lower()} "
            f"{self.category.lower()} {self.primary_category.lower()}"
        )
        return any(n in text for n in ("refund", "reversal", "returned", "return"))

    @property
    def is_card_payment_credit(self) -> bool:
        if not self.is_income:
            return False
        if self.is_credit_card_payment:
            return True
        text = f"{self.name.lower()} {self.description.lower()}"
        kind = self.account_type.lower().strip()
        if not kind:
            return "payment thank you" in text
        if kind != "credit" or self._is_refund_like():
            return False
        pfc = f"{self.raw_pfc_primary} {self.raw_pfc_detailed}".upper()
        return (
            "LOAN_DISBURSEMENTS" in pfc
            or "LOAN_PAYMENTS" in pfc
            or "TRANSFER_IN" in pfc
            or "payment" in text
            or "autopay" in text
        )

    @property
    def income_amount(self) -> float:
        return self.display_amount if self.kind == "income" else 0.0

    @property
    def card_payment_amount(self) -> float:
        return self.display_amount if self.is_card_payment_credit else 0.0


def build_transactions(
    tx_rows: list[dict], account_meta: dict, rules: dict[str, str], account_ids=None
) -> list[Tx]:
    """Parsed, de-duplicated, optionally limited to `account_ids` (the app's
    visibleTransactions)."""
    wanted = set(account_ids) if account_ids else None
    seen: set[str] = set()
    out = []
    unique_rows = []
    for row in tx_rows:
        tx = Tx(row, account_meta, rules)
        if tx.dedupe_key in seen:
            continue
        unique_rows.append(row)
        seen.add(tx.dedupe_key)
        if wanted is not None and tx.account_id not in wanted:
            continue
        out.append(tx)
    # Decided over every account, like the app: a refund can match a purchase on any of them.
    account_types = {
        account_id: str((meta or {}).get("account_type") or "").strip()
        for account_id, meta in account_meta.items()
    }
    decided = classify_rows(unique_rows, rules, account_types)
    for tx in out:
        if tx.id in decided:
            tx.kind, tx.bucket = decided[tx.id]
    return out


# ── AiSummaryService.build ──────────────────────────────────────────────


def _is_transfer_like_for_analysis(tx: Tx, category: str) -> bool:
    if not tx.is_expense:
        return False
    combined = f"{tx.raw_pfc_primary.lower()} {tx.raw_pfc_detailed.lower()}"
    if any(
        n in combined
        for n in ("loan_payments", "credit_card_payment", "transfer_out", "transfer_in", "internal")
    ):
        return True
    text = " ".join([category, tx.transaction_type, tx.name, tx.description]).lower()
    return any(
        n in text
        for n in (
            "internal transfer",
            "transfer from",
            "transfer to",
            "zelle",
            "venmo",
            "cash app",
            "credit card payment",
            "loan payment",
            "payment thank you",
            "autopay",
        )
    )


def _month_key(day) -> str:
    return f"{day.year}-{day.month:02d}"


def _clamp01(value: float) -> float:
    return 0.0 if value < 0 else 1.0 if value > 1 else value


def _empty_month():
    return {
        "income": 0.0,
        "expenses": 0.0,
        "card_payments_in": 0.0,
        "card_payments_out": 0.0,
        "tx_count": 0,
        "expense_tx_count": 0,
    }


def _window():
    return {"income": 0.0, "expenses": 0.0, "tx_count": 0, "expense_tx_count": 0}


def build_summary(
    transactions: list[Tx],
    budget_progress: list[dict],
    *,
    now: dt.datetime,
    focus_month: str,
    all_year: bool,
    all_accounts: bool,
    scope_label: str,
    account_type: str = "",
    tz_name: str = "",
) -> dict:
    """focus_month is 'YYYY-MM' (for all_year, any month of that year). `now` is the user's
    local time, naive."""
    year, mon = (int(p) for p in focus_month.split("-"))
    if all_year:
        mon = 1
    anchor = dt.datetime(year, mon, 1)
    next_month_start = dt.datetime(year + (mon == 12), 1 if mon == 12 else mon + 1, 1)
    anchor_end = now if now < next_month_start else next_month_start

    def days_before(base, n):
        return base - dt.timedelta(days=n)

    anchor_cutoffs = {7: days_before(anchor_end, 7), 30: days_before(anchor_end, 30)}
    anchor_cutoffs[90] = days_before(anchor_end, 90)
    rolling_cutoffs = {n: days_before(now, n) for n in (7, 30, 90)}
    cutoff_recent_days = anchor - dt.timedelta(days=120)

    windows_anchor = {n: _window() for n in (7, 30, 90)}
    windows_rolling = {n: _window() for n in (7, 30, 90)}
    category_totals_30d: dict[str, float] = {}
    month_totals: dict[str, dict] = {}
    month_category_totals: dict[str, dict[str, float]] = {}
    day_totals: dict[str, dict] = {}
    year_totals: dict[int, dict] = {}
    annual_year = anchor.year
    annual_income = annual_expenses = 0.0
    annual_expense_tx_count = 0
    annual_category_totals: dict[str, float] = {}
    annual_expenses_only: list[Tx] = []
    category_totals_all: dict[str, float] = {}
    active_days: set[str] = set()
    recent_30d_active_days: set[str] = set()
    earliest = latest = None
    expense_tx_count_all = 0
    transfer_like_count = 0

    for tx in transactions:
        category = tx.bucket or tx.category
        when = dt.datetime(tx.date.year, tx.date.month, tx.date.day)
        day_key = tx.date.isoformat()
        active_days.add(day_key)
        if when >= rolling_cutoffs[30]:
            recent_30d_active_days.add(day_key)
        earliest = tx.date if earliest is None or tx.date < earliest else earliest
        latest = tx.date if latest is None or tx.date > latest else latest
        month_key = _month_key(tx.date)
        month_bucket = month_totals.setdefault(month_key, _empty_month())
        day_bucket = day_totals.setdefault(day_key, {"income": 0.0, "expenses": 0.0, "tx_count": 0})
        year_bucket = year_totals.setdefault(
            tx.date.year, {"income": 0.0, "expenses": 0.0, "tx_count": 0}
        )
        month_bucket["tx_count"] += 1
        day_bucket["tx_count"] += 1
        year_bucket["tx_count"] += 1
        in_anchor = {n: anchor_cutoffs[n] <= when < anchor_end for n in (7, 30, 90)}
        in_rolling = {n: when >= rolling_cutoffs[n] for n in (7, 30, 90)}
        for n in (7, 30, 90):
            if in_anchor[n]:
                windows_anchor[n]["tx_count"] += 1
            if in_rolling[n]:
                windows_rolling[n]["tx_count"] += 1

        if tx.is_income:
            month_bucket["card_payments_in"] += tx.card_payment_amount
            income = tx.income_amount
            month_bucket["income"] += income
            day_bucket["income"] += income
            year_bucket["income"] += income
            for n in (7, 30, 90):
                if in_anchor[n]:
                    windows_anchor[n]["income"] += income
                if in_rolling[n]:
                    windows_rolling[n]["income"] += income
            if tx.date.year == annual_year:
                annual_income += income
            if tx.kind == "refund":
                # Money back for a purchase lowers spending in that purchase's category.
                refund = tx.expense_amount
                month_bucket["expenses"] += refund
                day_bucket["expenses"] += refund
                year_bucket["expenses"] += refund
                for n in (7, 30, 90):
                    if in_anchor[n]:
                        windows_anchor[n]["expenses"] += refund
                    if in_rolling[n]:
                        windows_rolling[n]["expenses"] += refund
                category_totals_all[category] = category_totals_all.get(category, 0.0) + refund
                per_month = month_category_totals.setdefault(month_key, {})
                per_month[category] = per_month.get(category, 0.0) + refund
                if in_anchor[30]:
                    category_totals_30d[category] = category_totals_30d.get(category, 0.0) + refund
                if tx.date.year == annual_year:
                    annual_expenses += refund
                    annual_category_totals[category] = (
                        annual_category_totals.get(category, 0.0) + refund
                    )
        elif tx.is_expense:
            expense = tx.expense_amount
            transfer_like = _is_transfer_like_for_analysis(tx, category)
            expense_tx_count_all += 1
            if tx.is_credit_card_payment:
                month_bucket["card_payments_out"] += tx.display_amount
            if transfer_like:
                transfer_like_count += 1
            month_bucket["expenses"] += expense
            month_bucket["expense_tx_count"] += 1
            day_bucket["expenses"] += expense
            year_bucket["expenses"] += expense
            for n in (7, 30, 90):
                if in_anchor[n]:
                    windows_anchor[n]["expenses"] += expense
                    windows_anchor[n]["expense_tx_count"] += 1
                if in_rolling[n]:
                    windows_rolling[n]["expenses"] += expense
                    windows_rolling[n]["expense_tx_count"] += 1
            if tx.date.year == annual_year:
                annual_expenses += expense
                annual_expense_tx_count += 1
                if expense:
                    annual_expenses_only.append(tx)
            # Whatever still counts as spending (a move between own accounts counts 0) belongs
            # to its category, so categories add up to the total, as on the Budget page.
            if expense:
                category_totals_all[category] = category_totals_all.get(category, 0.0) + expense
                per_month = month_category_totals.setdefault(month_key, {})
                per_month[category] = per_month.get(category, 0.0) + expense
                if in_anchor[30]:
                    category_totals_30d[category] = category_totals_30d.get(category, 0.0) + expense
                if tx.date.year == annual_year:
                    annual_category_totals[category] = (
                        annual_category_totals.get(category, 0.0) + expense
                    )

    recent = [
        {
            "id": tx.id,
            "date": tx.date.isoformat(),
            "name": tx.name,
            "amount": tx.amount,
            "category": tx.bucket or tx.category,
            "type": tx.transaction_type,
            "account_id": tx.account_id,
        }
        for tx in sorted(transactions, key=lambda t: (t.date, t.id), reverse=True)[:5]
    ]

    def ranked(mapping):
        return sorted(mapping.items(), key=lambda kv: kv[1], reverse=True)

    top_categories = [{"category": k, "amount": v} for k, v in ranked(category_totals_30d)[:5]]

    def clamped_ratio(item):
        spent, limit = float(item["spent"]), float(item["limit"])
        if limit <= 0:
            return 0.0
        return max(0.0, min(1.5, spent / limit))

    budget_alerts = [
        {
            "category": b["category"],
            "spent": b["spent"],
            "limit": b["limit"],
            "ratio": clamped_ratio(b),
        }
        for b in budget_progress
        if clamped_ratio(b) >= 1
    ][:3]
    budgets = {
        "month": _month_key(anchor),
        "items": []
        if all_year
        else [
            {"category": b["category"], "spent": b["spent"], "limit": b["limit"]}
            for b in budget_progress
            if float(b["limit"]) > 0
        ],
    }

    month_keys = sorted(month_totals)[-36:]
    month_index = {}
    for month in month_keys:
        bucket = month_totals[month]
        cats = ranked(month_category_totals.get(month, {}))
        month_index[month] = {
            "income": bucket["income"],
            "expenses": bucket["expenses"],
            "card_payments_in": bucket["card_payments_in"],
            "card_payments_out": bucket["card_payments_out"],
            "tx_count": bucket["tx_count"],
            "expense_tx_count": bucket["expense_tx_count"],
            "top_category": {"name": cats[0][0], "amount": cats[0][1]} if cats else None,
            "categories": dict(cats[:12]),
        }

    day_keys = sorted(day_totals)
    day_index_recent = {
        d: dict(day_totals[d])
        for d in day_keys
        if dt.datetime.fromisoformat(d) >= cutoff_recent_days
    }
    month_day_index = {
        month: [{"date": d, **day_totals[d]} for d in day_keys if d.startswith(f"{month}-")]
        for month in list(reversed(month_keys))[:6]
    }
    year_index = {str(y): dict(year_totals[y]) for y in sorted(year_totals)}

    def by_expenses(rows):
        return sorted(rows, key=lambda r: r["expenses"], reverse=True)

    highest_months = by_expenses(
        [{"month": m, "expenses": v["expenses"]} for m, v in month_index.items()]
    )
    highest_days = by_expenses(
        [{"date": d, "expenses": v["expenses"]} for d, v in day_index_recent.items()]
    )
    year_months = [m for m in month_index if m.startswith(f"{annual_year}-")]
    monthly_ranking = by_expenses(
        [{"month": m, "expenses": month_index[m]["expenses"]} for m in year_months]
    )
    trend = []
    previous = None
    for month in sorted(year_months):
        current = month_index[month]["expenses"]
        change = (current - previous) / previous if previous is not None and previous > 0 else None
        trend.append({"month": month, "expenses": current, "mom_change_pct": change})
        previous = current
    monthly_top = [
        {
            "month": m,
            "category": month_index[m]["top_category"]["name"],
            "amount": month_index[m]["top_category"]["amount"],
        }
        for m in year_months
        if month_index[m]["top_category"]
    ]
    anomalies = [
        {
            "date": tx.date.isoformat(),
            "name": tx.name,
            "amount": tx.expense_amount,
            "category": tx.bucket or tx.category,
        }
        for tx in sorted(annual_expenses_only, key=lambda t: t.expense_amount, reverse=True)[:5]
    ]

    days_span = (latest - earliest).days + 1 if earliest and latest else 0
    coverage_recent = len(recent_30d_active_days) / 30.0
    transfer_ratio = transfer_like_count / expense_tx_count_all if expense_tx_count_all else 0.0
    tx_score = _clamp01(windows_rolling[30]["tx_count"] / 20.0)
    coverage_score = _clamp01(coverage_recent)
    history_score = _clamp01(days_span / 120.0)
    noise_score = _clamp01(1.0 - transfer_ratio)
    score = _clamp01(
        tx_score * 0.35 + coverage_score * 0.3 + history_score * 0.2 + noise_score * 0.15
    )
    warnings = []
    if windows_rolling[30]["tx_count"] < 5 or coverage_recent < 0.2:
        warnings.append("sparse_recent_data")
    if 0 < days_span < 60:
        warnings.append("possible_missing_history")
    if transfer_ratio > 0.4:
        warnings.append("contains_transfer_like_noise")

    def in_period(tx):
        if all_year:
            return tx.date.year == anchor.year
        return tx.date.year == anchor.year and tx.date.month == anchor.month

    income_month = sum(tx.income_amount for tx in transactions if in_period(tx))
    expenses_month = sum(tx.expense_amount for tx in transactions if in_period(tx))

    def window_block(windows):
        return {
            "last_7d": {k: windows[7][k] for k in ("income", "expenses", "tx_count")},
            "last_30d": dict(windows[30]),
            "last_90d": {k: windows[90][k] for k in ("income", "expenses", "tx_count")},
        }

    a30 = windows_anchor[30]
    return {
        "version": SUMMARY_VERSION,
        "generated_at": now.isoformat(),
        "scope": "all_accounts" if all_accounts else "single_account",
        "scope_label": scope_label,
        "account_type": account_type,
        "data_coverage": {
            "transaction_count_total": len(transactions),
            "range_start": earliest.isoformat() if earliest else None,
            "range_end": latest.isoformat() if latest else None,
            "days_span": days_span,
            "active_days": len(active_days),
            "coverage_ratio_recent_30d": coverage_recent,
        },
        "confidence": {
            "score": score,
            "overall": "high" if score >= 0.75 else ("medium" if score >= 0.45 else "low"),
            "reasons": warnings,
            "components": {
                "tx_count_recent_30d": tx_score,
                "coverage_recent_30d": coverage_score,
                "history_span": history_score,
                "noise_penalty_adjusted": noise_score,
            },
        },
        "warnings": warnings,
        "category_index": category_totals_all,
        "time_anchor": {
            "selected_month": _month_key(anchor),
            "selected_year": anchor.year,
            "tz": tz_name,
        },
        "window_days": 30,
        "window_definition": {
            "windows_anchor": "anchor_based_selected_month",
            "windows_rolling": "rolling_from_generated_at",
        },
        "windows_anchor": window_block(windows_anchor),
        "windows_rolling": window_block(windows_rolling),
        "year_index": year_index,
        "month_index": month_index,
        "day_index_recent": day_index_recent,
        "month_day_index": month_day_index,
        "rankings": {
            "highest_spending_months": highest_months[:12],
            "highest_spending_days_recent": highest_days[:10],
        },
        "totals": {
            "income_30d": a30["income"],
            "expenses_30d": a30["expenses"],
            "net_30d": a30["income"] - a30["expenses"],
            "tx_count_30d": a30["tx_count"],
            "expense_tx_count_30d": a30["expense_tx_count"],
            "income_month": income_month,
            "expenses_month": expenses_month,
            "net_month": income_month - expenses_month,
        },
        "top_expense_categories": top_categories,
        "recent_transactions": recent,
        "budget_alerts": budget_alerts,
        "budgets": budgets,
        "annual_summary": {
            "year": annual_year,
            "totals": {
                "income_year": annual_income,
                "expenses_year": annual_expenses,
                "net_year": annual_income - annual_expenses,
                "expense_tx_count_year": annual_expense_tx_count,
            },
            "monthly_breakdown": [
                {
                    "month": m,
                    "income": month_index[m]["income"],
                    "expenses": month_index[m]["expenses"],
                }
                for m in year_months
            ],
            "top_expense_categories_year": [
                {"category": k, "amount": v} for k, v in ranked(annual_category_totals)[:10]
            ],
            "monthly_expense_ranking": monthly_ranking,
            "monthly_expense_trend": trend,
            "monthly_top_categories": monthly_top,
            "daily_expense_totals": [
                {"date": d, "amount": day_totals[d]["expenses"]}
                for d in day_keys
                if d.startswith(f"{annual_year}-")
            ],
            "anomalies_top": anomalies,
        },
    }


# ── Request context, database and cache ─────────────────────────────────


def parse_context(raw) -> dict | None:
    """The app's `context` block: {account_ids: [...], hidden_account_ids: [...], scope_label, selected_month
    ('YYYY-MM', or 'YYYY' for the all-year view), today: 'YYYY-MM-DD', tz}. None when unusable."""
    if not isinstance(raw, dict):
        return None
    today_text = str(raw.get("today") or "")[:10]
    try:
        today = dt.date.fromisoformat(today_text)
    except ValueError:
        today = dt.date.today()
    selected = str(raw.get("selected_month") or "").strip()
    all_year = bool(_YEAR_RE.match(selected))
    if all_year:
        month = f"{selected}-01"
    elif _MONTH_RE.match(selected):
        month = selected
    else:
        month = _month_key(today)

    def id_list(key: str) -> list[str]:
        ids = raw.get(key)
        return sorted(
            {str(a).strip()[:128] for a in ids if str(a).strip()}
            if isinstance(ids, list)
            else set()
        )[:20]

    return {
        "account_ids": id_list("account_ids"),
        # Hidden in the app: left out everywhere, as if never linked.
        "hidden_account_ids": id_list("hidden_account_ids"),
        "scope_label": str(raw.get("scope_label") or "")[:64],
        "month": month,
        "all_year": all_year,
        "today": today,
        "tz": str(raw.get("tz") or "")[:64],
    }


def _load(user_id: str, tx_rows=None) -> tuple[list[dict], dict, dict[str, str], dict[str, str]]:
    from supabase_repo import supabase
    from user_model import fetch_all_transactions, fetch_category_names, fetch_rules

    accounts = (
        supabase.table("accounts")
        .select("plaid_account_id,name,account_type,subtype")
        .eq("user_id", user_id)
        .execute()
    ).data or []
    account_meta = {str(a.get("plaid_account_id") or "").strip(): a for a in accounts}
    return (
        fetch_all_transactions(user_id) if tx_rows is None else tx_rows,
        account_meta,
        fetch_rules(user_id),
        fetch_category_names(user_id),
    )


def summary_for(user_id: str, context: dict, tx_rows=None) -> dict:
    """Build (or reuse) the summary for a parsed context. Raises on database errors; the
    caller falls back to the app-sent summary."""
    from user_model import fetch_budget_rows

    hidden = context.get("hidden_account_ids") or []
    key = (user_id, tuple(context["account_ids"]), tuple(hidden), context["month"])
    key += (context["all_year"],)
    key += (context["today"].isoformat(),)
    now_ts = time.time()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and hit[0] > now_ts:
            return hit[1]

    rows, account_meta, rules, names = _load(user_id, tx_rows)
    if hidden:
        hidden_set = set(hidden)
        rows = [r for r in rows if str(r.get("plaid_account_id") or "").strip() not in hidden_set]
    account_ids = context["account_ids"]
    txs = build_transactions(rows, account_meta, rules, account_ids or None)
    progress = []
    if not context["all_year"]:
        # Budgets cover every linked account, whichever one is selected (as in the app).
        progress = build_budget_progress(
            fetch_budget_rows(user_id, context["month"]),
            names,
            rows,
            rules,
            context["month"],
        )
    types = {tx.account_type.lower().strip() for tx in txs if tx.account_type.strip()}
    summary = build_summary(
        txs,
        progress,
        # Noon: the app's windows run from "now" minus N days, and any time after midnight
        # puts the same calendar days inside them.
        now=dt.datetime.combine(context["today"], dt.time(12, 0)),
        focus_month=context["month"],
        all_year=context["all_year"],
        all_accounts=not account_ids,
        scope_label=context["scope_label"]
        or ("Overall (All Accounts)" if not account_ids else "Selected account"),
        account_type=types.pop() if account_ids and len(types) == 1 else "",
        tz_name=context["tz"],
    )
    if not account_ids:
        # Alerts are per user (all accounts), so only the all-accounts view gets them.
        summary["alert_history"] = fetch_alert_history(user_id, context["month"])
    with _cache_lock:
        _cache[key] = (now_ts + _CACHE_TTL_SECONDS, summary)
    return summary


ALERT_HISTORY_MONTHS = 6


def fetch_alert_history(user_id: str, month: str) -> list[dict]:
    """Budget alerts for `month` and the ALERT_HISTORY_MONTHS before it, newest first: the
    finished months' month-end overruns and this month's open alerts. [] on any error."""
    from supabase_repo import supabase
    from user_model import previous_months

    months = previous_months(month, ALERT_HISTORY_MONTHS) + [month]
    try:
        rows = (
            supabase.table("budget_alerts")
            .select("month,category,kind,spent,limit_amount,resolved_at")
            .eq("user_id", user_id)
            .gte("month", months[0])
            .lte("month", month)
            .execute()
        ).data or []
    except Exception as error:
        print(f"alert history skipped for user {user_id}: {type(error).__name__}")
        return []
    return [
        {
            "month": r["month"],
            "category": r["category"],
            "kind": r["kind"],
            "spent": float(r.get("spent") or 0),
            "limit": float(r.get("limit_amount") or 0),
        }
        for r in sorted(rows, key=lambda r: (r["month"], r["category"]), reverse=True)
        if not r.get("resolved_at")
    ]


def invalidate(user_id: str) -> None:
    with _cache_lock:
        for key in [k for k in _cache if k[0] == user_id]:
            _cache.pop(key, None)
