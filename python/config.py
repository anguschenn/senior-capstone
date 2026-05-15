"""Centralised configuration loaded once from environment variables."""

import os
import threading

import certifi
from dotenv import load_dotenv

os.environ["SSL_CERT_FILE"] = certifi.where()
os.environ.setdefault("SSL_CERT_FILE", certifi.where())
os.environ.setdefault("REQUESTS_CA_BUNDLE", certifi.where())

# Ensure project-local python/.env values win over inherited shell variables.
# This avoids accidental overrides from global env placeholders (e.g. SUPABASE_KEY=placeholder_key).
load_dotenv(override=True)


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
PLAID_PRODUCTS = [
    p.strip() for p in os.getenv("PLAID_PRODUCTS", "transactions").split(",") if p.strip()
]
PLAID_COUNTRY_CODES = [
    c.strip() for c in os.getenv("PLAID_COUNTRY_CODES", "US").split(",") if c.strip()
]
PLAID_REDIRECT_URI = _empty_to_none("PLAID_REDIRECT_URI")

# ── AI model providers ───────────────────────────────────────────────
AI_PROVIDER = (_empty_to_none("AI_PROVIDER") or "ollama").strip().lower()
# Default to V2 router; keep env override for rollback.
AI_ROUTER_V2_ENABLED = os.getenv("AI_ROUTER_V2_ENABLED", "1").strip() in {"1", "true", "TRUE"}
OLLAMA_MODEL = _empty_to_none("OLLAMA_MODEL") or "llama3"
OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")
OPENROUTER_API_KEY = _empty_to_none("OPENROUTER_API_KEY")
OPENROUTER_MODEL = _empty_to_none("OPENROUTER_MODEL") or "openai/gpt-4o-mini"
OPENROUTER_BASE_URL = os.getenv("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")
OPENROUTER_HTTP_REFERER = _empty_to_none("OPENROUTER_HTTP_REFERER")
OPENROUTER_APP_TITLE = _empty_to_none("OPENROUTER_APP_TITLE")

# ── Backend API auth ─────────────────────────────────────────────────
INTERNAL_API_KEY = _empty_to_none("INTERNAL_API_KEY")

# ── Caching ──────────────────────────────────────────────────────────
SPENDING_SNAPSHOT_CACHE_TTL_SECONDS = int(os.getenv("SPENDING_SNAPSHOT_CACHE_TTL_SECONDS", "60"))
_SPENDING_SNAPSHOT_CACHE: dict = {}
_SPENDING_SNAPSHOT_CACHE_LOCK = threading.Lock()

# ── Rate limiting ────────────────────────────────────────────────────
AI_RATE_LIMIT_PER_MINUTE = int(os.getenv("AI_RATE_LIMIT_PER_MINUTE", "12"))
AI_MAX_REQUEST_BYTES = int(os.getenv("AI_MAX_REQUEST_BYTES", "16384"))  # 16 KB

# ── App metadata / runtime ───────────────────────────────────────────
APP_VERSION = os.getenv("APP_VERSION", "")
GIT_SHA = os.getenv("GIT_SHA", "")
HOST = os.getenv("HOST", "127.0.0.1")
