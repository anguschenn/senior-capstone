"""Plaid routes that need no Plaid call: /api/info and the /api/transactions sync summary."""

import unittest
from unittest import mock

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


if __name__ == "__main__":
    unittest.main()
