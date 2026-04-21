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
            supabase.table("transactions")
            .select("date,amount,merchant_name,name,pfc_primary,pfc_detailed,pending")
            .eq("user_id", user_id)
            .order("date", desc=True)
            .limit(400)
            .execute()
        )

        txs = rows.data or []
        if not txs:
            return "No transactions available."

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
            amount = raw_amount if isinstance(raw_amount, (int, float)) else 0.0
            amount = float(amount)

            if parsed_date >= cutoff:
                if amount < 0:
                    income_30d += abs(amount)
                else:
                    expense_30d += amount
                    detailed = (row.get("pfc_detailed") or "").strip()
                    primary = (row.get("pfc_primary") or "").strip()
                    category = detailed or primary or "Uncategorized"
                    category_totals[category] = category_totals.get(category, 0.0) + amount

            if len(recent_lines) < 12:
                merchant = (row.get("merchant_name") or "").strip()
                fallback_name = (row.get("name") or "").strip()
                label = merchant or fallback_name or "Unknown merchant"
                direction = "income" if amount < 0 else "expense"
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
