"""Account sync must not write bank account details to the server log."""

import contextlib
import io
import unittest
from types import SimpleNamespace
from unittest import mock

import plaid_sync

ACCOUNTS = [
    {
        "account_id": "acc-1",
        "name": "Secret Joint Checking",
        "official_name": "Bank Premier Checking",
        "type": "depository",
        "subtype": "checking",
        "mask": "4321",
        "balances": {"current": 1234.56, "available": 1200.0},
    },
    {
        "account_id": "acc-2",
        "name": "Rainy Day Savings",
        "type": "depository",
        "subtype": "savings",
        "mask": "9876",
        "balances": {"current": 50.0},
    },
]


class AccountSyncLoggingTests(unittest.TestCase):
    def test_logs_only_the_account_count(self):
        response = SimpleNamespace(to_dict=lambda: {"accounts": ACCOUNTS})
        out = io.StringIO()
        with (
            mock.patch.object(plaid_sync, "supabase", mock.MagicMock()),
            mock.patch.object(plaid_sync.client, "accounts_get", return_value=response),
            contextlib.redirect_stdout(out),
        ):
            saved = plaid_sync.save_accounts_to_supabase("user-1", "item-row-1", "access-1")

        self.assertEqual(saved, 2)
        log = out.getvalue()
        self.assertIn("2 account(s)", log)
        for detail in ("Secret Joint Checking", "Rainy Day Savings", "checking", "4321"):
            self.assertNotIn(detail, log)


if __name__ == "__main__":
    unittest.main()
