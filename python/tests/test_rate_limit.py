"""AI rate limiting behind Render's proxy: per user when signed in, per client IP otherwise."""

import unittest
from unittest import mock

from route_helpers import OTHER_TOKEN, OTHER_USER_ID, USER_ID, VALID_TOKEN, app_client, headers
from werkzeug.middleware.proxy_fix import ProxyFix

import auth

CHAT_BODY = {"prompt": "how much did I spend", "history": [], "spending_summary": {}}
PROXY_ADDR = {"REMOTE_ADDR": "10.0.0.1"}  # every request arrives from the proxy


def _limit(n):
    return mock.patch.object(auth, "AI_RATE_LIMIT_PER_MINUTE", n)


class PerUserBucketTests(unittest.TestCase):
    def test_two_users_behind_one_proxy_get_separate_buckets(self):
        with app_client() as client, _limit(1):

            def chat(token):
                return client.post(
                    "/api/ai/chat",
                    json=CHAT_BODY,
                    headers=headers(token, **{"X-Forwarded-For": "203.0.113.7"}),
                    environ_base=PROXY_ADDR,
                ).status_code

            self.assertEqual(chat(VALID_TOKEN), 200)
            self.assertEqual(chat(VALID_TOKEN), 429)
            self.assertEqual(chat(OTHER_TOKEN), 200)
            self.assertIn(f"ai:user:{USER_ID}", auth._rate_buckets)
            self.assertIn(f"ai:user:{OTHER_USER_ID}", auth._rate_buckets)

    def test_user_bucket_follows_the_user_across_ips(self):
        with app_client() as client, _limit(1):
            for ip, expected in (("203.0.113.7", 200), ("198.51.100.9", 429)):
                response = client.post(
                    "/api/ai/chat",
                    json=CHAT_BODY,
                    headers=headers(VALID_TOKEN, **{"X-Forwarded-For": ip}),
                    environ_base=PROXY_ADDR,
                )
                self.assertEqual(response.status_code, expected, ip)

    def test_unauthenticated_requests_do_not_consume_a_bucket(self):
        with app_client() as client, _limit(1):
            response = client.post("/api/ai/chat", json=CHAT_BODY, headers=headers())
            self.assertEqual(response.status_code, 401)
            response = client.post("/api/ai/chat", json=CHAT_BODY, headers=headers(VALID_TOKEN))
            self.assertEqual(response.status_code, 200)


class PerIpBucketTests(unittest.TestCase):
    """/api/ai/budget_suggest has no user auth yet, so it is keyed by client IP."""

    def _suggest(self, client, forwarded_for=None):
        extra = {"X-Forwarded-For": forwarded_for} if forwarded_for else {}
        return client.post(
            "/api/ai/budget_suggest",
            json={},
            headers=headers(**extra),
            environ_base=PROXY_ADDR,
        ).status_code

    def test_two_client_ips_behind_one_proxy_get_separate_buckets(self):
        with app_client() as client, _limit(1):
            self.assertEqual(self._suggest(client, "203.0.113.7"), 200)
            self.assertEqual(self._suggest(client, "203.0.113.7"), 429)
            self.assertEqual(self._suggest(client, "198.51.100.9"), 200)
            self.assertIn("ai:ip:203.0.113.7", auth._rate_buckets)
            self.assertIn("ai:ip:198.51.100.9", auth._rate_buckets)

    def test_only_the_hop_added_by_the_proxy_is_trusted(self):
        # A client can prepend anything to X-Forwarded-For; Render appends the real
        # peer last. With x_for=1 only that last entry is used, so spoofing fails.
        with app_client() as client, _limit(1):
            self.assertEqual(self._suggest(client, "1.1.1.1, 203.0.113.7"), 200)
            self.assertEqual(self._suggest(client, "2.2.2.2, 203.0.113.7"), 429)
            self.assertNotIn("ai:ip:1.1.1.1", auth._rate_buckets)
            self.assertNotIn("ai:ip:2.2.2.2", auth._rate_buckets)

    def test_without_forwarded_header_falls_back_to_peer_address(self):
        with app_client() as client, _limit(1):
            self.assertEqual(self._suggest(client), 200)
            self.assertIn("ai:ip:10.0.0.1", auth._rate_buckets)


class ProxyFixConfigTests(unittest.TestCase):
    def test_app_trusts_exactly_one_forwarded_for_hop_and_nothing_else(self):
        with app_client() as client:
            wsgi = client.application.wsgi_app
        self.assertIsInstance(wsgi, ProxyFix)
        self.assertEqual(wsgi.x_for, 1)
        self.assertEqual((wsgi.x_proto, wsgi.x_host, wsgi.x_port, wsgi.x_prefix), (0, 0, 0, 0))


if __name__ == "__main__":
    unittest.main()
