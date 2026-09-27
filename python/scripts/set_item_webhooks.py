#!/usr/bin/env python3
"""Point every stored Plaid Item at PLAID_WEBHOOK_URL (/item/webhook/update).

Items linked before webhooks existed have no webhook URL, so Plaid never notifies us about
them. This fixes that without re-linking (no Trial Item is consumed). Plaid answers each
update with an ITEM/WEBHOOK_UPDATE_ACKNOWLEDGED webhook, which is a free end-to-end test of
delivery and signature verification — watch the Render logs for it.

Run from python/ with the production .env:
    python scripts/set_item_webhooks.py            # dry run: lists what would change
    python scripts/set_item_webhooks.py --apply    # actually update
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import plaid  # noqa: E402
from plaid.model.item_webhook_update_request import ItemWebhookUpdateRequest  # noqa: E402

from config import PLAID_ENV, PLAID_WEBHOOK_URL  # noqa: E402
from plaid_sync import _safe_api_exception_body, client  # noqa: E402
from supabase_repo import supabase  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="perform the updates")
    args = parser.parse_args()

    if not PLAID_WEBHOOK_URL or not PLAID_WEBHOOK_URL.startswith("https://"):
        print("PLAID_WEBHOOK_URL must be set to the public https:// webhook URL.")
        return 1

    rows = (
        supabase.table("plaid_items").select("item_id,institution_name,access_token").execute()
    ).data or []
    print(f"PLAID_ENV={PLAID_ENV}  webhook={PLAID_WEBHOOK_URL}  items={len(rows)}")

    failures = 0
    for row in rows:
        label = f"{row.get('institution_name') or 'unknown bank'} ({row['item_id']})"
        if not row.get("access_token"):
            print(f"  skip   {label}: no access token")
            continue
        if not args.apply:
            print(f"  would update {label}")
            continue
        try:
            client.item_webhook_update(
                ItemWebhookUpdateRequest(
                    access_token=row["access_token"], webhook=PLAID_WEBHOOK_URL
                )
            )
            print(f"  updated {label}")
        except plaid.ApiException as error:
            failures += 1
            code = _safe_api_exception_body(error).get("error_code", "PLAID_API_ERROR")
            print(f"  FAILED  {label}: {code}")

    if not args.apply:
        print("Dry run only. Re-run with --apply to update.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
