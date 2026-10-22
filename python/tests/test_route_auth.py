"""Supabase user auth on AI/system endpoints (the x-api-key ships in the app bundle)."""

import unittest
from unittest import mock

from route_helpers import USER_ID, VALID_TOKEN, app_client, headers
from supabase_auth.errors import AuthApiError, AuthRetryableError

import auth
from ai.providers import generate_llm_reply as real_provider

SECRET_DETAIL = "upstream exploded at http://10.0.0.5:11434 with key sk-abc123"


def _assert_no_detail(test, response):
    text = response.get_data(as_text=True)
    test.assertNotIn(SECRET_DETAIL, text)
    test.assertNotIn("sk-abc123", text)


class _AuthCases:
    """Cases every user-authenticated endpoint must pass; subclasses set path and body."""

    method = "post"
    path = ""
    body = None

    def _call(self, client, token=None):
        return getattr(client, self.method)(self.path, json=self.body, headers=headers(token))

    def test_missing_token_is_401(self):
        with app_client() as client:
            response = self._call(client)
        self.assertEqual(response.status_code, 401)

    def test_unknown_token_is_401(self):
        with app_client() as client:
            response = self._call(client, "not-a-real-token")
        self.assertEqual(response.status_code, 401)

    def test_token_rejected_by_supabase_is_401_without_detail(self):
        rejected = AuthApiError(SECRET_DETAIL, 403, "bad_jwt")
        with (
            app_client() as client,
            mock.patch.object(auth.supabase.auth, "get_user", side_effect=rejected),
        ):
            response = self._call(client, "expired-token")
        self.assertEqual(response.status_code, 401)
        _assert_no_detail(self, response)

    def test_supabase_outage_is_not_401_and_hides_detail(self):
        # A Supabase network failure must not look like "logged out" to the client.
        outage = AuthRetryableError(SECRET_DETAIL, 503)
        with (
            app_client() as client,
            mock.patch.object(auth.supabase.auth, "get_user", side_effect=outage),
        ):
            response = self._call(client, VALID_TOKEN)
        self.assertNotEqual(response.status_code, 401)
        _assert_no_detail(self, response)

    def test_missing_api_key_is_still_401(self):
        with app_client() as client:
            response = getattr(client, self.method)(
                self.path, json=self.body, headers={"Authorization": f"Bearer {VALID_TOKEN}"}
            )
        self.assertEqual(response.status_code, 401)


class PredictAuthTests(_AuthCases, unittest.TestCase):
    path = "/api/ai/predict"
    body = {"type": "budget_overrun_forecast", "budget_progress": []}

    def test_valid_token_succeeds(self):
        with app_client() as client:
            response = self._call(client, VALID_TOKEN)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["type"], "budget_overrun_forecast")

    def test_internal_error_hides_exception_text(self):
        with app_client() as client:
            service = client.application.config["predict_service"]
            with mock.patch.object(
                service, "handle_predict", side_effect=RuntimeError(SECRET_DETAIL)
            ):
                response = self._call(client, VALID_TOKEN)
        self.assertTrue(response.get_json()["fallback_used"])
        _assert_no_detail(self, response)


class RefreshInsightsAuthTests(_AuthCases, unittest.TestCase):
    path = "/api/refresh_insights"

    def test_valid_token_refreshes_that_user(self):
        from routes import budget_routes

        with (
            app_client() as client,
            mock.patch.object(budget_routes, "run_post_sync") as run,
        ):
            response = self._call(client, VALID_TOKEN)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(run.call_args.args[0], USER_ID)

    def test_internal_error_hides_exception_text(self):
        from routes import budget_routes

        with (
            app_client() as client,
            mock.patch.object(
                budget_routes, "run_post_sync", side_effect=RuntimeError(SECRET_DETAIL)
            ),
        ):
            response = self._call(client, VALID_TOKEN)
        self.assertEqual(response.status_code, 500)
        _assert_no_detail(self, response)


class PingAuthTests(_AuthCases, unittest.TestCase):
    method = "get"
    path = "/api/ai/ping"

    def _provider(self, **kwargs):
        return mock.patch(
            "ai.providers.generate_llm_reply",
            mock.create_autospec(real_provider, **kwargs),
        )

    def test_valid_token_succeeds(self):
        with app_client() as client, self._provider(return_value="pong"):
            response = self._call(client, VALID_TOKEN)
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.get_json()["ok"])

    def test_provider_failure_hides_exception_text(self):
        with app_client() as client, self._provider(side_effect=RuntimeError(SECRET_DETAIL)):
            response = self._call(client, VALID_TOKEN)
        self.assertEqual(response.status_code, 500)
        self.assertFalse(response.get_json()["ok"])
        self.assertNotIn("detail", response.get_json())
        _assert_no_detail(self, response)

    def test_ping_is_rate_limited(self):
        with (
            app_client() as client,
            self._provider(return_value="pong"),
            mock.patch.object(auth, "AI_RATE_LIMIT_PER_MINUTE", 2),
        ):
            codes = [self._call(client, VALID_TOKEN).status_code for _ in range(3)]
        self.assertEqual(codes, [200, 200, 429])


class ChatAuthTests(_AuthCases, unittest.TestCase):
    path = "/api/ai/chat"
    body = {"prompt": "how much did I spend", "history": [], "spending_summary": {}}


class SuggestCategoryAuthTests(_AuthCases, unittest.TestCase):
    path = "/api/ai/suggest_category"
    body = {"merchant_name": "Starbucks"}


class LinkTokenAuthTests(_AuthCases, unittest.TestCase):
    """Starting a Plaid Link needs a signed-in user, not just the bundled x-api-key."""

    path = "/api/create_link_token"
    body = {}

    def test_valid_token_sends_the_user_id_to_plaid(self):
        from types import SimpleNamespace

        from routes import plaid_routes

        sent = []

        def fake_create(link_request):
            sent.append(link_request)
            return SimpleNamespace(to_dict=lambda: {"link_token": "link-sandbox-123"})

        with (
            app_client() as client,
            mock.patch.object(plaid_routes, "PLAID_CLIENT_ID", "id"),
            mock.patch.object(plaid_routes, "PLAID_SECRET", "secret"),
            mock.patch.object(plaid_routes.client, "link_token_create", side_effect=fake_create),
        ):
            response = self._call(client, VALID_TOKEN)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json(), {"link_token": "link-sandbox-123"})
        self.assertEqual(sent[0].user.client_user_id, USER_ID)


if __name__ == "__main__":
    unittest.main()
