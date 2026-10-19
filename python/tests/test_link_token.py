"""Link tokens carry the Supabase user id as Plaid client_user_id and need a signed-in user."""

import unittest
from types import SimpleNamespace
from unittest import mock

from route_helpers import USER_ID, VALID_TOKEN, app_client, headers
from supabase_auth.errors import AuthApiError

import auth
from routes import plaid_routes

SECRET_DETAIL = "plaid client exploded: secret=abc123 host=production.plaid.com"


def _link_response():
    return SimpleNamespace(to_dict=lambda: {"link_token": "link-sandbox-123"})


class _PlaidPatches:
    def setUp(self):
        self.link_token_create = mock.Mock(return_value=_link_response())
        patches = [
            mock.patch.object(plaid_routes, "PLAID_CLIENT_ID", "client-id"),
            mock.patch.object(plaid_routes, "PLAID_SECRET", "secret"),
            mock.patch.object(plaid_routes.client, "link_token_create", self.link_token_create),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def _client_user_id(self):
        (link_request,) = self.link_token_create.call_args.args
        return link_request["user"]["client_user_id"]


class CreateLinkTokenTests(_PlaidPatches, unittest.TestCase):
    def _post(self, client, token=None):
        return client.post("/api/create_link_token", headers=headers(token))

    def test_uses_supabase_user_id_as_client_user_id(self):
        with app_client() as client:
            response = self._post(client, VALID_TOKEN)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["link_token"], "link-sandbox-123")
        self.assertEqual(self._client_user_id(), USER_ID)

    def test_missing_token_is_401_and_never_reaches_plaid(self):
        with app_client() as client:
            response = self._post(client)
        self.assertEqual(response.status_code, 401)
        self.link_token_create.assert_not_called()

    def test_invalid_token_is_401(self):
        with app_client() as client:
            response = self._post(client, "not-a-real-token")
        self.assertEqual(response.status_code, 401)
        self.link_token_create.assert_not_called()

    def test_token_rejected_by_supabase_is_401_without_detail(self):
        rejected = AuthApiError(SECRET_DETAIL, 403, "bad_jwt")
        with (
            app_client() as client,
            mock.patch.object(auth.supabase.auth, "get_user", side_effect=rejected),
        ):
            response = self._post(client, "expired")
        self.assertEqual(response.status_code, 401)
        self.assertNotIn(SECRET_DETAIL, response.get_data(as_text=True))

    def test_unexpected_error_does_not_leak_exception_text(self):
        self.link_token_create.side_effect = RuntimeError(SECRET_DETAIL)
        with app_client() as client:
            response = self._post(client, VALID_TOKEN)
        self.assertEqual(response.status_code, 500)
        self.assertNotIn(SECRET_DETAIL, response.get_data(as_text=True))
        self.assertNotIn("abc123", response.get_data(as_text=True))


class CreateLinkTokenUpdateTests(_PlaidPatches, unittest.TestCase):
    def test_uses_supabase_user_id_as_client_user_id(self):
        fake_db = mock.MagicMock()
        query = fake_db.table.return_value.select.return_value.eq.return_value
        query.limit.return_value.execute.return_value = SimpleNamespace(
            data=[{"access_token": "access-sandbox-1"}]
        )
        with app_client() as client, mock.patch.object(plaid_routes, "supabase", fake_db):
            response = client.post(
                "/api/create_link_token_update", json={}, headers=headers(VALID_TOKEN)
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self._client_user_id(), USER_ID)
        fake_db.table.return_value.select.return_value.eq.assert_called_once_with(
            "user_id", USER_ID
        )


if __name__ == "__main__":
    unittest.main()
