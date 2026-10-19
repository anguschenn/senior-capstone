"""transactions/sync "modified" entries must refresh every field Plaid can change."""

import datetime as dt
import unittest
from collections import defaultdict
from types import SimpleNamespace
from unittest import mock

import plaid_sync

MODIFIED = {
    "transaction_id": "txn-1",
    "account_id": "acc-1",
    "amount": 12.5,
    "date": dt.date(2026, 10, 3),
    "name": "STARBUCKS STORE 123",
    "merchant_name": "Starbucks",
    "pending": False,
    "personal_finance_category": {"primary": "FOOD_AND_DRINK", "detailed": "FOOD_AND_DRINK_COFFEE"},
}


def _sync_page():
    page = {
        "next_cursor": "cursor-2",
        "added": [],
        "modified": [MODIFIED],
        "removed": [],
        "has_more": False,
    }
    return SimpleNamespace(to_dict=lambda: page)


def _run_sync():
    """Run one sync against a fake Supabase with one mock per table; return the tables."""
    tables = defaultdict(mock.MagicMock)
    fake_db = mock.MagicMock()
    fake_db.table.side_effect = lambda name: tables[name]
    # No stored cursor: the sync starts from the beginning.
    cursor_query = tables["plaid_items"].select.return_value.eq.return_value.eq.return_value
    cursor_query.execute.return_value = SimpleNamespace(data=[])
    with (
        mock.patch.object(plaid_sync, "supabase", fake_db),
        mock.patch.object(plaid_sync.client, "transactions_sync", return_value=_sync_page()),
    ):
        stats = plaid_sync.sync_transactions_to_supabase("user-1", "item-row-1", "access-1")
    return stats, tables


class ModifiedTransactionTests(unittest.TestCase):
    def test_modified_transaction_updates_date_name_and_merchant(self):
        stats, tables = _run_sync()
        self.assertEqual(stats["modified"], 1)
        tables["transactions"].update.assert_called_once_with(
            {
                "amount": 12.5,
                "date": "2026-10-03",
                "name": "STARBUCKS STORE 123",
                "merchant_name": "Starbucks",
                "pending": False,
                "pfc_primary": "FOOD_AND_DRINK",
                "pfc_detailed": "FOOD_AND_DRINK_COFFEE",
            }
        )

    def test_modified_update_is_scoped_to_the_user(self):
        # The service-role key bypasses RLS, so every write must filter by user_id.
        _, tables = _run_sync()
        first = tables["transactions"].update.return_value.eq
        second = first.return_value.eq
        filters = {first.call_args.args, second.call_args.args}
        self.assertEqual(filters, {("plaid_transaction_id", "txn-1"), ("user_id", "user-1")})
        second.return_value.execute.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
