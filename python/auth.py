"""API-key / authentication middleware and helpers."""

import hmac
import threading
import time

from flask import jsonify, request
from supabase import Client

from config import AI_RATE_LIMIT_PER_MINUTE, INTERNAL_API_KEY
from supabase_repo import supabase

# ── Simple in-memory sliding-window rate limiter ─────────────────────
_rate_buckets: dict[str, list[float]] = {}
_rate_lock = threading.Lock()


def _check_rate_limit(key: str, limit: int = AI_RATE_LIMIT_PER_MINUTE) -> bool:
    """Return True if within limit, False if exceeded."""
    now = time.time()
    window = 60.0
    with _rate_lock:
        timestamps = _rate_buckets.get(key, [])
        timestamps = [t for t in timestamps if now - t < window]
        if len(timestamps) >= limit:
            _rate_buckets[key] = timestamps
            return False
        timestamps.append(now)
        _rate_buckets[key] = timestamps
        return True


def is_rate_limited_for_ai() -> bool:
    """Check per-IP rate limit for AI endpoints. Returns True if blocked."""
    ip = request.remote_addr or "unknown"
    return not _check_rate_limit(f"ai:{ip}", AI_RATE_LIMIT_PER_MINUTE)


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
    response = auth_client.auth.get_user(token)
    user = getattr(response, "user", None)
    user_id = getattr(user, "id", None)
    if not user_id:
        raise UserAuthError("Invalid Supabase access token")
    return user_id
