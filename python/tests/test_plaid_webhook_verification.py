import hashlib
import json
import time
import unittest
import uuid

import jwt
from cryptography.hazmat.primitives.asymmetric import ec

from plaid_webhook import verify_plaid_webhook

BODY = json.dumps(
    {
        "webhook_type": "TRANSACTIONS",
        "webhook_code": "SYNC_UPDATES_AVAILABLE",
        "item_id": "item-123",
    }
).encode()


class PlaidWebhookVerificationTests(unittest.TestCase):
    def setUp(self):
        self.private_key = ec.generate_private_key(ec.SECP256R1())
        # Unique kid per test so the module-level key cache never leaks between tests.
        self.kid = f"kid-{uuid.uuid4()}"
        jwk = json.loads(jwt.algorithms.ECAlgorithm.to_jwk(self.private_key.public_key()))
        jwk.update({"kid": self.kid, "alg": "ES256", "use": "sig", "expired_at": None})
        self.jwk = jwk
        self.fetches = 0

    def get_jwk(self, key_id):
        self.fetches += 1
        self.assertEqual(key_id, self.kid)
        return self.jwk

    def sign(self, body=BODY, iat=None, kid=None, key=None, alg="ES256"):
        claims = {
            "iat": int(time.time()) if iat is None else iat,
            "request_body_sha256": hashlib.sha256(body).hexdigest(),
        }
        return jwt.encode(
            claims, key or self.private_key, algorithm=alg, headers={"kid": kid or self.kid}
        )

    def verify(self, body, token):
        return verify_plaid_webhook(body, token, get_jwk=self.get_jwk)

    def test_valid_webhook_is_accepted(self):
        ok, reason = self.verify(BODY, self.sign())
        self.assertTrue(ok, reason)

    def test_key_is_cached_after_first_fetch(self):
        self.verify(BODY, self.sign())
        self.verify(BODY, self.sign())
        self.assertEqual(self.fetches, 1)

    def test_missing_header_is_rejected(self):
        ok, _ = self.verify(BODY, None)
        self.assertFalse(ok)

    def test_tampered_body_is_rejected(self):
        token = self.sign()
        tampered = BODY.replace(b"item-123", b"item-999")
        ok, reason = self.verify(tampered, token)
        self.assertFalse(ok)
        self.assertIn("body hash", reason)

    def test_stale_webhook_is_rejected(self):
        ok, reason = self.verify(BODY, self.sign(iat=int(time.time()) - 6 * 60))
        self.assertFalse(ok)
        self.assertIn("stale", reason)

    def test_signature_from_another_key_is_rejected(self):
        attacker_key = ec.generate_private_key(ec.SECP256R1())
        ok, reason = self.verify(BODY, self.sign(key=attacker_key))
        self.assertFalse(ok)
        self.assertIn("signature", reason)

    def test_non_es256_alg_is_rejected(self):
        token = jwt.encode(
            {"iat": int(time.time()), "request_body_sha256": hashlib.sha256(BODY).hexdigest()},
            "attacker-guessed-shared-secret-value-000",
            algorithm="HS256",
            headers={"kid": self.kid},
        )
        ok, reason = self.verify(BODY, token)
        self.assertFalse(ok)
        self.assertIn("alg", reason)
        self.assertEqual(self.fetches, 0)

    def test_expired_plaid_key_is_rejected(self):
        self.jwk["expired_at"] = 1700000000
        ok, reason = self.verify(BODY, self.sign())
        self.assertFalse(ok)
        self.assertIn("key", reason)


if __name__ == "__main__":
    unittest.main()
