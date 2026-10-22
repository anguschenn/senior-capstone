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


class PendingPostsTests(unittest.TestCase):
    """Plaid posts a pending transaction as a new transaction_id that names the pending one
    in pending_transaction_id, and removes the pending one in the same sync."""

    def _posted(self, db):
        run_sync(
            db,
            added=[
                plaid_tx(
                    "dinner-posted", 80.0, "2026-10-02", pending_transaction_id="dinner-pending"
                )
            ],
            removed=[{"transaction_id": "dinner-pending"}],
        )

    def test_payback_linked_to_a_pending_purchase_follows_it_when_it_posts(self):
        db = base_db(
            [
                db_row("dinner-pending", 80.0, "2026-09-30", pending=True),
                db_row("venmo-1", -40.0, "2026-10-01", name="VENMO FROM SAM"),
            ],
            [
                {
                    "user_id": USER_ID,
                    "plaid_transaction_id": "venmo-1",
                    "paid_back_purchase_id": "dinner-pending",
                }
            ],
        )
        self._posted(db)
        ids = {r["plaid_transaction_id"] for r in db.tables["transactions"]}
        self.assertEqual(ids, {"dinner-posted", "venmo-1"})
        posted = next(
            r for r in db.tables["transactions"] if r["plaid_transaction_id"] == "dinner-posted"
        )
        self.assertEqual(posted["pending_transaction_id"], "dinner-pending")
        (decision,) = db.tables["transaction_decisions"]
        self.assertEqual(decision["paid_back_purchase_id"], "dinner-posted")

    def test_choice_saved_on_a_pending_transaction_moves_to_the_posted_one(self):
        db = base_db(
            [db_row("dinner-pending", 80.0, "2026-09-30", pending=True)],
            [{"user_id": USER_ID, "plaid_transaction_id": "dinner-pending", "shared_amount": 40.0}],
        )
        self._posted(db)
        (decision,) = db.tables["transaction_decisions"]
        self.assertEqual(decision["plaid_transaction_id"], "dinner-posted")
        self.assertEqual(decision["shared_amount"], 40.0)

    def test_another_users_decisions_are_left_alone(self):
        other = {
            "user_id": "user-2",
            "plaid_transaction_id": "x",
            "paid_back_purchase_id": "dinner-pending",
        }
        db = base_db([db_row("dinner-pending", 80.0, "2026-09-30", pending=True)], [other])
        self._posted(db)
        self.assertEqual(db.tables["transaction_decisions"], [other])

    def test_the_payback_still_counts_after_the_purchase_posts(self):
        from budget_progress import classify_rows, fetch_decisions

        db = base_db(
            [
                db_row("dinner-pending", 80.0, "2026-09-30", pending=True),
                db_row("venmo-1", -40.0, "2026-10-01", name="VENMO FROM SAM"),
            ],
            [
                {
                    "user_id": USER_ID,
                    "plaid_transaction_id": "venmo-1",
                    "paid_back_purchase_id": "dinner-pending",
                }
            ],
        )
        self._posted(db)
        decided = classify_rows(
            db.tables["transactions"], {}, decisions=fetch_decisions(USER_ID, db)
        )
        self.assertEqual(decided["venmo-1"].kind, "payback")
        self.assertEqual(decided["dinner-posted"].paid_back, 40.0)

    def test_rows_are_still_stored_before_migration_018(self):
        db = base_db()
        real_table = db.table

        def table(name):
            query = real_table(name)
            if name == "transactions":
                real_upsert = query.upsert

                def upsert(rows, **kwargs):
                    if any("pending_transaction_id" in r for r in rows):
                        raise RuntimeError("column pending_transaction_id does not exist")
                    return real_upsert(rows, **kwargs)

                query.upsert = upsert
            return query

        db.table = table
        self._posted(db)
        (row,) = db.tables["transactions"]
        self.assertEqual(row["plaid_transaction_id"], "dinner-posted")


if __name__ == "__main__":
    unittest.main()
