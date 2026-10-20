#!/usr/bin/env python3
"""Build category_month_stats, budget_alerts and budget_suggestions for existing users.

After migration 014 these tables fill in on each user's next bank sync; this fills them now.
Safe to re-run: every write is an upsert, and decided suggestions are never touched.

Run from python/ with the production .env:
    python scripts/backfill_user_model.py            # dry run: what would be written
    python scripts/backfill_user_model.py --apply    # write it
"""

import argparse
import datetime as dt
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from budget_progress import build_budget_progress  # noqa: E402
from supabase_repo import supabase  # noqa: E402
from user_model import (  # noqa: E402
    build_alerts,
    build_category_month_stats,
    build_suggestions,
    fetch_all_transactions,
    fetch_budget_rows,
    fetch_category_names,
    fetch_rules,
    refresh_user_model,
)


def _dry_run(user_id: str, today: dt.date) -> str:
    month = f"{today.year}-{today.month:02d}"
    tx_rows = fetch_all_transactions(user_id)
    rules = fetch_rules(user_id)
    stats = build_category_month_stats(tx_rows, rules)
    budget_rows = fetch_budget_rows(user_id, month)
    if not budget_rows:
        return f"{len(tx_rows)} transactions, {len(stats)} stat rows, no {month} budget rows"
    names = fetch_category_names(user_id)
    alerts = build_alerts(build_budget_progress(budget_rows, names, tx_rows, rules, month), today)
    suggestions = build_suggestions(budget_rows, names, tx_rows, rules, month)
    lines = [
        f"{len(tx_rows)} transactions, {len(stats)} stat rows, {len(alerts)} alerts, "
        f"{len(suggestions)} suggestions"
    ]
    lines += [f"    alert  {a['category']}: {a['kind']}" for a in alerts]
    lines += [
        f"    suggest {s['category']}: {s['current_limit']} -> {s['suggested_limit']}"
        for s in suggestions
    ]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="write the rows")
    args = parser.parse_args()

    user_ids = sorted(
        {
            str(r["user_id"])
            for r in (supabase.table("plaid_items").select("user_id").execute()).data or []
            if r.get("user_id")
        }
    )
    today = dt.date.today()
    print(f"{len(user_ids)} users with linked banks; {'APPLYING' if args.apply else 'dry run'}")
    for user_id in user_ids:
        if args.apply:
            result = refresh_user_model(user_id, today)
            print(
                f"{user_id}: {len(result['tx_rows'])} transactions, stats={result['stats']} "
                f"alerts={result['alerts']} suggestions={result['suggestions']}"
            )
        else:
            print(f"{user_id}: {_dry_run(user_id, today)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
