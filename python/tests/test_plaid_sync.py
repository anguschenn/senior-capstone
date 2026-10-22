"""transactions_sync results written to Supabase (plaid_sync._sync_transactions_unlocked),
with Plaid and Supabase replaced by in-memory fakes."""

import datetime as dt
import unittest
from types import SimpleNamespace
from unittest import mock

from fake_supabase import FakeSupabase

import plaid_sync

USER_ID = "user-1"
ITEM_ID = "item-1"


def plaid_tx(tx_id, amount, date, name="DINNER", account="acc-1", pending=False, **extra):
    return {
        "transaction_id": tx_id,
        "account_id": account,
        "amount": amount,
        "date": dt.date.fromisoformat(date),
        "name": name,
        "merchant_name": name.title(),
        "pending": pending,
        "personal_finance_category": {"primary": "FOOD_AND_DRINK", "detailed": "FOOD_AND_DRINK_X"},
        **extra,
    }


def db_row(tx_id, amount, date, name="DINNER", account="acc-1", pending=False):
    return {
        "user_id": USER_ID,
        "plaid_transaction_id": tx_id,
        "plaid_account_id": account,
        "amount": amount,
        "date": date,
        "name": name,
        "merchant_name": name.title(),
        "pending": pending,
    }


def run_sync(db, added=(), modified=(), removed=()):
    page = {
        "added": list(added),
        "modified": list(modified),
        "removed": list(removed),
        "next_cursor": "cursor-2",
        "has_more": False,
    }
    fake_client = SimpleNamespace(
        transactions_sync=lambda _request: SimpleNamespace(to_dict=lambda: page)
    )
    with (
        mock.patch.object(plaid_sync, "supabase", db),
        mock.patch.object(plaid_sync, "client", fake_client),
        mock.patch.object(plaid_sync, "TransactionsSyncRequest", lambda **_: None),
    ):
        return plaid_sync._sync_transactions_unlocked(USER_ID, ITEM_ID, "access-token")


def base_db(transactions=(), decisions=()):
    return FakeSupabase(
        {
            "plaid_items": [{"id": ITEM_ID, "user_id": USER_ID, "cursor": "cursor-1"}],
            "transactions": list(transactions),
            "transaction_decisions": list(decisions),
        }
    )


class ModifiedTests(unittest.TestCase):
    def test_modified_transaction_takes_the_new_date_name_and_account(self):
        db = base_db([db_row("tx-1", 80.0, "2026-09-30", name="SQ *DINNER PENDING")])
        run_sync(
            db,
            modified=[plaid_tx("tx-1", 82.5, "2026-10-01", name="DINNER", account="acc-2")],
        )
        (row,) = db.tables["transactions"]
        self.assertEqual(row["date"], "2026-10-01")
        self.assertEqual(row["name"], "DINNER")
        self.assertEqual(row["merchant_name"], "Dinner")
        self.assertEqual(row["plaid_account_id"], "acc-2")
        self.assertEqual(row["amount"], 82.5)


if __name__ == "__main__":
    unittest.main()
