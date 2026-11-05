import unittest
from unittest import mock

from route_helpers import VALID_TOKEN, app_client, headers


class PushRouteTests(unittest.TestCase):
    def test_config_requires_user_authentication(self):
        with app_client() as client:
            response = client.get("/api/push/config", headers=headers())
        self.assertEqual(response.status_code, 401)

    def test_config_returns_only_public_key(self):
        from routes import push_routes

        with (
            app_client() as client,
            mock.patch.object(
                push_routes,
                "public_push_config",
                return_value={"enabled": True, "vapid_public_key": "public-key"},
            ),
        ):
            response = client.get("/api/push/config", headers=headers(VALID_TOKEN))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.get_json(),
            {"enabled": True, "vapid_public_key": "public-key"},
        )

    def test_subscription_rejects_non_chrome_endpoint(self):
        body = {
            "subscription": {
                "endpoint": "https://example.com/fcm/send/token",
                "keys": {"p256dh": "key", "auth": "key"},
            }
        }
        with app_client() as client:
            response = client.post(
                "/api/push/subscriptions",
                json=body,
                headers=headers(VALID_TOKEN),
            )
        self.assertEqual(response.status_code, 400)

    def test_subscription_saves_for_authenticated_user(self):
        from routes import push_routes

        subscription = {
            "endpoint": "https://fcm.googleapis.com/fcm/send/test",
            "keys": {"p256dh": "p256dh", "auth": "auth"},
        }
        with (
            app_client() as client,
            mock.patch.object(push_routes, "save_subscription") as save,
            mock.patch.object(push_routes, "process_user_notifications"),
        ):
            response = client.post(
                "/api/push/subscriptions",
                json={"subscription": subscription},
                headers=headers(VALID_TOKEN),
            )
        self.assertEqual(response.status_code, 201)
        save.assert_called_once()
        self.assertEqual(save.call_args.args[0], "user-123")


if __name__ == "__main__":
    unittest.main()
