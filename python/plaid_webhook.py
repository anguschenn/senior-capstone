"""Plaid webhook verification (the Plaid-Verification JWT) and background dispatch.

The webhook route sits outside /api/, so it is NOT behind the x-api-key gate — Plaid cannot
send that header. This signature check is therefore the only thing standing between the
internet and a sync, and every step of Plaid's verification recipe is enforced:
  1. header alg is ES256, and it names a key id (kid)
  2. the public key for that kid comes from Plaid (/webhook_verification_key/get), not the request
  3. the JWT signature verifies against that key
  4. iat is no more than 5 minutes old
  5. the SHA-256 of the raw request body equals the request_body_sha256 claim
"""

import hashlib
import hmac
import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import jwt
from plaid.model.webhook_verification_key_get_request import WebhookVerificationKeyGetRequest

MAX_WEBHOOK_AGE_SECONDS = 5 * 60

_key_cache: dict[str, object] = {}
_key_cache_lock = threading.Lock()

# Webhook work runs here so the route can answer Plaid inside its 10-second window.
# Two workers: syncs for different Items can overlap; the same Item is serialised by
# plaid_sync's per-item lock.
executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="plaid-webhook")


def _fetch_jwk(key_id: str) -> dict:
    from plaid_sync import client

    response = client.webhook_verification_key_get(WebhookVerificationKeyGetRequest(key_id=key_id))
    return response.to_dict()["key"]


def _public_key_for(key_id: str, get_jwk):
    with _key_cache_lock:
        cached = _key_cache.get(key_id)
    if cached is not None:
        return cached
    jwk = get_jwk(key_id)
    if jwk.get("expired_at") is not None:
        raise ValueError(f"verification key {key_id} has expired")
    public_key = jwt.algorithms.ECAlgorithm.from_jwk(json.dumps(jwk))
    with _key_cache_lock:
        _key_cache[key_id] = public_key
    return public_key


def verify_plaid_webhook(body: bytes, token: str | None, *, get_jwk=_fetch_jwk, now=time.time):
    """Return (ok, reason). Never raises; reason is safe to log."""
    if not token:
        return False, "missing Plaid-Verification header"
    try:
        header = jwt.get_unverified_header(token)
    except jwt.PyJWTError:
        return False, "malformed JWT header"
    if header.get("alg") != "ES256":
        return False, f"unexpected alg {header.get('alg')!r}"
    key_id = header.get("kid")
    if not key_id:
        return False, "missing kid"

    try:
        public_key = _public_key_for(key_id, get_jwk)
    except Exception as error:
        return False, f"could not load verification key: {type(error).__name__}"

    try:
        claims = jwt.decode(
            token,
            public_key,
            algorithms=["ES256"],
            options={"require": ["iat", "request_body_sha256"], "verify_iat": False},
        )
    except jwt.PyJWTError as error:
        return False, f"signature check failed: {type(error).__name__}"

    age = now() - float(claims["iat"])
    if age > MAX_WEBHOOK_AGE_SECONDS or age < -60:
        return False, f"stale or future-dated webhook (age {int(age)}s)"

    body_hash = hashlib.sha256(body).hexdigest()
    if not hmac.compare_digest(body_hash, str(claims["request_body_sha256"])):
        return False, "body hash mismatch"
    return True, "ok"
