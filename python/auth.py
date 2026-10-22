"""API-key / authentication middleware and helpers."""

import hmac
import threading
import time

from flask import jsonify, request
from supabase import Client
from supabase_auth.errors import AuthError, AuthRetryableError

from config import AI_RATE_LIMIT_PER_MINUTE, INTERNAL_API_KEY
from supabase_repo import supabase

# ── Simple in-memory sliding-window rate limiter ─────────────────────
_rate_buckets: dict[str, list[float]] = {}
_rate_lock = threading.Lock()
_RATE_WINDOW_SECONDS = 60.0
_last_sweep = 0.0


def _sweep_idle_buckets(now: float) -> None:
    """Drop keys with no request inside the window, at most once a window, so one key per
    user id and client IP doesn't stay in memory forever. Caller holds _rate_lock."""
    global _last_sweep
    if now - _last_sweep < _RATE_WINDOW_SECONDS:
        return
    _last_sweep = now
    for key in [
        k for k, ts in _rate_buckets.items() if not ts or now - ts[-1] >= _RATE_WINDOW_SECONDS
    ]:
        del _rate_buckets[key]


def _check_rate_limit(key: str, limit: int = AI_RATE_LIMIT_PER_MINUTE) -> bool:
    """Return True if within limit, False if exceeded."""
    now = time.time()
    window = _RATE_WINDOW_SECONDS
    with _rate_lock:
        _sweep_idle_buckets(now)
        timestamps = _rate_buckets.get(key, [])
        timestamps = [t for t in timestamps if now - t < window]
        if len(timestamps) >= limit:
            _rate_buckets[key] = timestamps
            return False
        timestamps.append(now)
        _rate_buckets[key] = timestamps
        return True


def is_rate_limited_for_ai(user_id: str | None = None) -> bool:
    """Check the AI rate limit. Returns True if blocked.

    Keyed by Supabase user id when the route has authenticated one, else by client IP.
    remote_addr is the real client only because app_factory wraps the app in
    ProxyFix(x_for=1); without it every request behind Render's proxy shares one bucket.
    """
    if user_id:
        key = f"ai:user:{user_id}"
    else:
        key = f"ai:ip:{request.remote_addr or 'unknown'}"
    return not _check_rate_limit(key, AI_RATE_LIMIT_PER_MINUTE)


def require_api_key():
    """Flask before_request hook: reject calls without valid x-api-key."""
    if request.method == "OPTIONS":
        return None
    if not request.path.startswith("/api/"):
        return None
    if not INTERNAL_API_KEY:
        return jsonify({"error": "Server misconfigured"}), 500
    provided = request.headers.get("x-api-key") or ""
    if not hmac.compare_digest(provided, INTERNAL_API_KEY):
        return jsonify({"error": "Unauthorized"}), 401
    return None


class UserAuthError(RuntimeError):
    pass


def require_supabase_user_id() -> str:
    auth_header = request.headers.get("Authorization") or ""
    token = ""
    if auth_header.lower().startswith("bearer "):
        token = auth_header[7:].strip()
    if not token:
        token = (request.headers.get("x-supabase-access-token") or "").strip()
    if not token:
        raise UserAuthError("Missing Supabase access token")

    auth_client: Client = supabase
    try:
        response = auth_client.auth.get_user(token)
    except AuthRetryableError:
        # Supabase unreachable or 5xx: not the caller's fault, so let the route's
        # generic handler answer instead of telling a signed-in user they are logged out.
        raise
    except AuthError as error:
        # Expired/forged/revoked token. The SDK message is not echoed to the client.
        raise UserAuthError("Invalid Supabase access token") from error
    user = getattr(response, "user", None)
    user_id = getattr(user, "id", None)
    if not user_id:
        raise UserAuthError("Invalid Supabase access token")
    return user_id
