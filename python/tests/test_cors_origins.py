import unittest

from flask import Flask
from flask_cors import CORS

from config import parse_allowed_origins


def _allowed_origin(origins, origin):
    """Access-Control-Allow-Origin a preflight from `origin` gets back (None = blocked)."""
    app = Flask(__name__)
    CORS(app, resources={r"/api/*": {"origins": origins}})

    @app.route("/api/ping")
    def ping():
        return "ok"

    response = app.test_client().open(
        "/api/ping",
        method="OPTIONS",
        headers={"Origin": origin, "Access-Control-Request-Method": "GET"},
    )
    return response.headers.get("Access-Control-Allow-Origin")


class AllowedOriginsTests(unittest.TestCase):
    def setUp(self):
        self.origins = parse_allowed_origins("http://localhost:*, https://smartspend.example.com")

    def test_any_localhost_port_is_allowed(self):
        for origin in ("http://localhost:52806", "http://localhost:8080", "http://localhost:3000"):
            with self.subTest(origin):
                self.assertEqual(_allowed_origin(self.origins, origin), origin)

    def test_exact_origins_still_work(self):
        origin = "https://smartspend.example.com"
        self.assertEqual(_allowed_origin(self.origins, origin), origin)

    def test_lookalike_origins_are_blocked(self):
        for origin in (
            "http://localhost.evil.com",
            "http://localhost.evil.com:8080",
            "http://localhost:8080.evil.com",
            "http://localhost:abc",
            "http://localhost",
            "https://localhost:8080",
            "http://127.0.0.1:8080",
            "https://evil.example",
        ):
            with self.subTest(origin):
                self.assertIsNone(_allowed_origin(self.origins, origin))

    def test_wildcard_anywhere_but_the_port_is_rejected(self):
        self.assertEqual(parse_allowed_origins("http://*.example.com,https://evil.*"), [])
        self.assertEqual(parse_allowed_origins("^http://.*$"), [])

    def test_empty_blocks_everything(self):
        self.assertEqual(parse_allowed_origins(""), [])
        self.assertIsNone(_allowed_origin([], "http://localhost:8080"))


if __name__ == "__main__":
    unittest.main()
