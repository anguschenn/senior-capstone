"""Pin the set of /api/ routes so endpoints are not added or revived by accident."""

import unittest

from route_helpers import VALID_TOKEN, app_client, headers

import plaid_sync

EXPECTED_API_ROUTES = {
    "/api/ai/budget_suggest",
    "/api/ai/chat",
    "/api/ai/ping",
    "/api/ai/predict",
    "/api/ai/suggest_category",
    "/api/budget_progress",
    "/api/create_link_token",
    "/api/create_link_token_update",
    "/api/health",
    "/api/info",
    "/api/set_access_token",
    "/api/transactions",
}


class RouteInventoryTests(unittest.TestCase):
    def test_api_routes_are_exactly_the_expected_set(self):
        with app_client() as client:
            rules = {r.rule for r in client.application.url_map.iter_rules()}
        self.assertEqual({r for r in rules if r.startswith("/api/")}, EXPECTED_API_ROUTES)

    def test_plaid_quickstart_endpoints_are_gone(self):
        # They returned (and printed to logs) full Plaid payloads, including account and
        # routing numbers from /auth/get, and nothing in the Flutter app calls them.
        with app_client() as client:
            for path in ("/api/auth", "/api/balance", "/api/accounts", "/api/item"):
                with self.subTest(path):
                    response = client.get(path, headers=headers(VALID_TOKEN))
                    self.assertEqual(response.status_code, 404)

    def test_full_response_logger_is_removed(self):
        self.assertFalse(hasattr(plaid_sync, "pretty_print_response"))


if __name__ == "__main__":
    unittest.main()
