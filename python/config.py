"""Centralised configuration loaded once from environment variables."""

import os
import threading

from dotenv import load_dotenv

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

# ── Teller ───────────────────────────────────────────────────────────
TELLER_ENV = os.getenv("TELLER_ENV", "sandbox")
TELLER_API_BASE = os.getenv("TELLER_API_BASE", "https://api.teller.io")
TELLER_PRODUCTS = os.getenv("TELLER_PRODUCTS", "transactions,balance").split(",")
TELLER_CERT_PATH = _empty_to_none("TELLER_CERT_PATH")
TELLER_KEY_PATH = _empty_to_none("TELLER_KEY_PATH")

# ── AI model providers ───────────────────────────────────────────────
OLLAMA_MODEL = _empty_to_none("OLLAMA_MODEL") or "llama3"
OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")

# ── Demo identity ────────────────────────────────────────────────────
DEMO_USER_ID = _empty_to_none("DEMO_USER_ID")
DEMO_BANK_CONNECTION_ID = _empty_to_none("DEMO_BANK_CONNECTION_ID")
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

# ── App metadata / runtime ───────────────────────────────────────────
APP_VERSION = os.getenv("APP_VERSION", "")
GIT_SHA = os.getenv("GIT_SHA", "")
HOST = os.getenv("HOST", "127.0.0.1")
