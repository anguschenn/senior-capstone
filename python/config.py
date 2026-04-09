"""Centralised configuration loaded once from environment variables."""

import os
import threading

from dotenv import load_dotenv

load_dotenv()


def _empty_to_none(field: str):
    value = os.getenv(field)
    if value is None or len(value) == 0:
        return None
    return value


# ── Flask ────────────────────────────────────────────────────────────
PORT = int(os.getenv("PORT", "8000"))
ENV = os.getenv("ENV", "development")  # development | production

# ── Supabase ─────────────────────────────────────────────────────────
SUPABASE_URL = os.getenv("SUPABASE_URL", "")
SUPABASE_KEY = os.getenv("SUPABASE_KEY", "")

# ── Plaid ────────────────────────────────────────────────────────────
PLAID_CLIENT_ID = os.getenv("PLAID_CLIENT_ID")
PLAID_SECRET = os.getenv("PLAID_SECRET")
PLAID_ENV = os.getenv("PLAID_ENV", "sandbox")
PLAID_PRODUCTS = os.getenv("PLAID_PRODUCTS", "transactions").split(",")
PLAID_COUNTRY_CODES = os.getenv("PLAID_COUNTRY_CODES", "US").split(",")
PLAID_REDIRECT_URI = _empty_to_none("PLAID_REDIRECT_URI")

# ── Gemini ───────────────────────────────────────────────────────────
GEMINI_API_KEY = _empty_to_none("GEMINI_API_KEY")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")

# ── Demo identity ────────────────────────────────────────────────────
DEMO_USER_ID = _empty_to_none("DEMO_USER_ID")
DEMO_PLAID_ITEM_ID = _empty_to_none("DEMO_PLAID_ITEM_ID")
INTERNAL_API_KEY = _empty_to_none("INTERNAL_API_KEY")

# ── Caching ──────────────────────────────────────────────────────────
SPENDING_SNAPSHOT_CACHE_TTL_SECONDS = int(
    os.getenv("SPENDING_SNAPSHOT_CACHE_TTL_SECONDS", "60")
)
_SPENDING_SNAPSHOT_CACHE: dict = {}
_SPENDING_SNAPSHOT_CACHE_LOCK = threading.Lock()

# ── Rate limiting ────────────────────────────────────────────────────
AI_RATE_LIMIT_PER_MINUTE = int(os.getenv("AI_RATE_LIMIT_PER_MINUTE", "12"))
AI_MAX_REQUEST_BYTES = int(os.getenv("AI_MAX_REQUEST_BYTES", "16384"))  # 16 KB
