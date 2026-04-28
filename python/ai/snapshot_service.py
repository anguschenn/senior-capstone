import datetime as dt
import time

from config import SPENDING_SNAPSHOT_CACHE_TTL_SECONDS
from supabase_repo import supabase


class SpendingSnapshotService:
    def __init__(self, ttl_seconds=SPENDING_SNAPSHOT_CACHE_TTL_SECONDS):
        self.ttl_seconds = max(1, int(ttl_seconds))
        self._cache = {}

    def _build_spending_snapshot(self, user_id):
        rows = (
            supabase.table("teller_transactions")
            .select(
                "date,amount,counterparty_name,description,teller_category,transaction_type,status,teller_account_id"
            )
            .eq("user_id", user_id)
            .order("date", desc=True)
            .limit(400)
            .execute()
        )

        txs = rows.data or []
        if not txs:
            return "No transactions available."

        account_ids = sorted(
            {
                row.get("teller_account_id")
                for row in txs
                if row.get("teller_account_id")
            }
        )
        account_name_by_id = {}
        account_meta_by_id = {}
        if account_ids:
            accounts = (
                supabase.table("teller_accounts")
                .select("teller_account_id,name,account_type,subtype")
                .eq("user_id", user_id)
                .in_("teller_account_id", account_ids)
                .execute()
            )
            for row in (accounts.data or []):
                account_id = row.get("teller_account_id")
                if not account_id:
                    continue
                account_name_by_id[account_id] = row.get("name") or ""
                account_meta_by_id[account_id] = {
                    "name": row.get("name") or "",
                    "account_type": row.get("account_type") or "",
                    "subtype": row.get("subtype") or "",
                }

        today = dt.date.today()
        cutoff = today - dt.timedelta(days=30)
        income_30d = 0.0
        expense_30d = 0.0
        category_totals = {}
        recent_lines = []

        for row in txs:
            raw_date = row.get("date")
            parsed_date = today
            if isinstance(raw_date, str):
                try:
                    parsed_date = dt.datetime.fromisoformat(raw_date[:10]).date()
                except Exception:
                    parsed_date = today

            raw_amount = row.get("amount")
            try:
                amount = float(raw_amount)
            except Exception:
                amount = 0.0

            account_meta = account_meta_by_id.get(row.get("teller_account_id"), {})
            account_name = account_name_by_id.get(row.get("teller_account_id"), "")
            uses_depository_sign = _uses_depository_polarity(
                account_name=account_meta.get("name") or account_name,
                account_type=account_meta.get("account_type") or "",
                account_subtype=account_meta.get("subtype") or "",
            )
            is_expense = amount < 0 if uses_depository_sign else amount > 0
            is_inflow = amount != 0 and not is_expense
            is_income = is_inflow and _is_deposit_income_signal(row)

            if parsed_date >= cutoff:
                if is_income:
                    income_30d += abs(amount)
                elif is_expense:
                    expense_30d += abs(amount)
                    category = (
                        row.get("teller_category")
                        or row.get("transaction_type")
                        or "Uncategorized"
                    )
                    category = category.strip()
                    category_totals[category] = (
                        category_totals.get(category, 0.0) + abs(amount)
                    )

            if len(recent_lines) < 12:
                merchant = (row.get("counterparty_name") or "").strip()
                fallback_name = (row.get("description") or "").strip()
                label = merchant or fallback_name or "Unknown merchant"
                direction = (
                    "income"
                    if is_income
                    else ("inflow_non_income" if is_inflow else "expense")
                )
                recent_lines.append(
                    f"- {parsed_date.isoformat()} | {label} | {direction} | ${abs(amount):.2f}"
                )

        top_categories = sorted(
            category_totals.items(),
            key=lambda item: item[1],
            reverse=True,
        )[:5]
        if top_categories:
            top_category_text = "\n".join(
                f"- {name}: ${total:.2f}" for name, total in top_categories
            )
        else:
            top_category_text = "- No expense categories in last 30 days."

        return (
            f"Snapshot window: last 30 days ending {today.isoformat()}\n"
            f"- Total income (30d): ${income_30d:.2f}\n"
            f"- Total expenses (30d): ${expense_30d:.2f}\n"
            f"- Net cash flow (30d): ${income_30d - expense_30d:.2f}\n"
            "Top expense categories (30d):\n"
            f"{top_category_text}\n"
            "Recent transactions:\n"
            f"{chr(10).join(recent_lines)}"
        )

    def invalidate(self, user_id):
        self._cache.pop(user_id, None)

    def get_cached_snapshot(self, user_id):
        now_ts = time.time()
        entry = self._cache.get(user_id)
        if entry and entry.get("expires_at", 0) > now_ts:
            return entry.get("value")

        snapshot = self._build_spending_snapshot(user_id)
        self._cache[user_id] = {
            "value": snapshot,
            "expires_at": now_ts + self.ttl_seconds,
        }
        return snapshot


def _uses_depository_polarity(
    account_name: str, account_type: str, account_subtype: str
) -> bool:
    account_type_key = (account_type or "").strip().lower()
    subtype_key = (account_subtype or "").strip().lower()
    if account_type_key == "depository":
        return True
    if account_type_key in {"credit", "loan"}:
        return False
    if subtype_key in {"checking", "savings"}:
        return True
    if "credit" in subtype_key:
        return False
    name_key = (account_name or "").lower()
    if "checking" in name_key or "saving" in name_key:
        return True
    if "credit" in name_key:
        return False
    return False


def _is_deposit_income_signal(row: dict) -> bool:
    description = str(row.get("description") or "").lower().replace("_", " ")
    return "deposit" in description
