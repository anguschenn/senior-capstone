"""Plaid routes that need no Plaid call: /api/info and the /api/transactions sync summary."""

import json
import unittest
from unittest import mock

import plaid
from fake_supabase import FakeSupabase
from route_helpers import USER_ID, VALID_TOKEN, app_client, headers

from routes import plaid_routes


class InfoTests(unittest.TestCase):
    def _info(self, client_id, secret, db=None):
        with (
            app_client() as client,
            mock.patch.object(plaid_routes, "PLAID_CLIENT_ID", client_id),
            mock.patch.object(plaid_routes, "PLAID_SECRET", secret),
            mock.patch.object(plaid_routes, "supabase", db or FakeSupabase()),
        ):
            return client.get("/api/info", headers=headers(VALID_TOKEN))

    def test_missing_plaid_keys_report_not_configured(self):
        response = self._info("", "")
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json["has_configured_identity"])
        self.assertEqual(response.json["identity_status"], "not_configured")

    def test_configured_keys_look_up_the_users_item(self):
        db = FakeSupabase({"plaid_items": [{"id": "item-1", "user_id": USER_ID}]})
        response = self._info("id", "secret", db)
        self.assertTrue(response.json["has_configured_identity"])
        self.assertEqual(response.json["identity_status"], "ready")


def login_required_error():
    error = plaid.ApiException(status=400, reason="Bad Request")
    error.body = json.dumps({"error_code": "ITEM_LOGIN_REQUIRED"})
    return error


class TransactionsSyncTests(unittest.TestCase):
    def _sync(self, results):
        db = FakeSupabase(
            {
                "plaid_items": [
                    {"id": item_id, "user_id": USER_ID, "access_token": f"token-{item_id}"}
                    for item_id in results
                ]
            }
        )

        def fake_sync(_user_id, item_id, _token):
            result = results[item_id]
            if isinstance(result, Exception):
                raise result
            return result

        with (
            app_client() as client,
            mock.patch.object(plaid_routes, "supabase", db),
            mock.patch.object(plaid_routes, "sync_transactions_to_supabase", fake_sync),
            mock.patch.object(plaid_routes, "record_sync"),
            mock.patch.object(plaid_routes, "run_post_sync"),
        ):
            return client.get("/api/transactions", headers=headers(VALID_TOKEN))

    def test_expired_bank_is_reported_when_another_bank_synced(self):
        response = self._sync(
            {
                "item-expired": login_required_error(),
                "item-ok": {"added": 1, "modified": 0, "removed": 0},
            }
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["login_required_items"], ["item-expired"])
        self.assertEqual(response.json["sync"]["added"], 1)

    def test_no_expired_bank_reports_an_empty_list(self):
        response = self._sync({"item-ok": {"added": 0, "modified": 0, "removed": 0}})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["login_required_items"], [])

    def test_only_expired_banks_still_answer_400(self):
        response = self._sync({"item-expired": login_required_error()})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json["error_code"], "ITEM_LOGIN_REQUIRED")


if __name__ == "__main__":
    unittest.main()
