"""Gemini API calls, prompt building, spending snapshot logic."""

import datetime as dt
import json
import ssl
import time
import urllib.error
import urllib.request

from config import (
    GEMINI_API_KEY,
    GEMINI_MODEL,
    SPENDING_SNAPSHOT_CACHE_TTL_SECONDS,
    _SPENDING_SNAPSHOT_CACHE,
    _SPENDING_SNAPSHOT_CACHE_LOCK,
)
from supabase_repo import supabase

try:
    import certifi
except Exception:
    certifi = None

# ── Gemini generation config ─────────────────────────────────────────
_GENERATION_CONFIG = {
    "maxOutputTokens": 512,
    "temperature": 0.4,
}

_MAX_RETRIES = 2
_BASE_TIMEOUT = 15  # seconds


def _generate_gemini_reply(prompt: str) -> str:
    """Call Gemini with timeout and exponential-backoff retry (up to _MAX_RETRIES)."""
    if not GEMINI_API_KEY:
        raise RuntimeError("Missing GEMINI_API_KEY")

    endpoint = (
        f"https://generativelanguage.googleapis.com/v1beta/models/"
        f"{GEMINI_MODEL}:generateContent?key={GEMINI_API_KEY}"
    )
    payload = {
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": _GENERATION_CONFIG,
    }
    data = json.dumps(payload).encode("utf-8")

    ssl_context = ssl.create_default_context()
    if certifi is not None:
        ssl_context.load_verify_locations(cafile=certifi.where())

    last_exc: Exception | None = None
    for attempt in range(_MAX_RETRIES + 1):
        timeout = _BASE_TIMEOUT * (2 ** attempt)
        try:
            req = urllib.request.Request(
                endpoint,
                data=data,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=timeout, context=ssl_context) as resp:
                raw = resp.read().decode("utf-8")
                parsed = json.loads(raw)

            candidates = parsed.get("candidates") or []
            if not candidates:
                raise RuntimeError("Gemini returned no candidates")
            content = (candidates[0] or {}).get("content") or {}
            parts = content.get("parts") or []
            if not parts:
                raise RuntimeError("Gemini returned empty content")
            text = (parts[0] or {}).get("text") or ""
            if not text.strip():
                raise RuntimeError("Gemini returned blank reply")
            return text

        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            last_exc = exc
            if attempt < _MAX_RETRIES:
                time.sleep(0.5 * (2 ** attempt))  # exponential back-off
                continue
            raise
        except Exception:
            raise

    raise last_exc  # type: ignore[misc]


# ── Spending snapshot ────────────────────────────────────────────────

def _build_spending_snapshot(user_id: str) -> str:
    rows = (
        supabase.table("transactions")
        .select("date,amount,merchant_name,name,pfc_primary,pfc_detailed,pending")
        .eq("user_id", user_id)
        .order("date", desc=True)
        .limit(400)
        .execute()
    )
    txs = rows.data or []
    if not txs:
        return "No transactions available."

    today = dt.date.today()
    cutoff = today - dt.timedelta(days=30)
    income_30d = 0.0
    expense_30d = 0.0
    category_totals: dict[str, float] = {}
    recent_lines: list[str] = []

    for row in txs:
        raw_date = row.get("date")
        parsed_date = today
        if isinstance(raw_date, str):
            try:
                parsed_date = dt.datetime.fromisoformat(raw_date[:10]).date()
            except Exception:
                parsed_date = today

        raw_amount = row.get("amount")
        amount = float(raw_amount) if isinstance(raw_amount, (int, float)) else 0.0

        if parsed_date >= cutoff:
            if amount < 0:
                income_30d += abs(amount)
            else:
                expense_30d += amount
                detailed = (row.get("pfc_detailed") or "").strip()
                primary = (row.get("pfc_primary") or "").strip()
                category = detailed or primary or "Uncategorized"
                category_totals[category] = category_totals.get(category, 0.0) + amount

        if len(recent_lines) < 3:
            merchant = (row.get("merchant_name") or "").strip()
            fallback_name = (row.get("name") or "").strip()
            label = merchant or fallback_name or "Unknown"
            direction = "income" if amount < 0 else "expense"
            recent_lines.append(
                f"- {parsed_date.isoformat()} | {label} | {direction} | ${abs(amount):.2f}"
            )

    top_categories = sorted(
        category_totals.items(), key=lambda item: item[1], reverse=True
    )[:3]
    top_category_text = (
        "\n".join(f"- {name}: ${total:.2f}" for name, total in top_categories)
        if top_categories
        else "- No expense categories in last 30 days."
    )

    return (
        f"30d window ending {today.isoformat()}\n"
        f"- Income: ${income_30d:.2f}\n"
        f"- Expenses: ${expense_30d:.2f}\n"
        f"- Net: ${income_30d - expense_30d:.2f}\n"
        f"Top categories:\n{top_category_text}\n"
        f"Recent:\n{chr(10).join(recent_lines)}"
    )


def invalidate_spending_snapshot_cache(user_id: str):
    with _SPENDING_SNAPSHOT_CACHE_LOCK:
        _SPENDING_SNAPSHOT_CACHE.pop(user_id, None)


def get_cached_spending_snapshot(user_id: str) -> str:
    now_ts = time.time()
    with _SPENDING_SNAPSHOT_CACHE_LOCK:
        entry = _SPENDING_SNAPSHOT_CACHE.get(user_id)
        if entry and entry.get("expires_at", 0) > now_ts:
            return entry.get("value")

    snapshot = _build_spending_snapshot(user_id)
    expires_at = now_ts + max(1, SPENDING_SNAPSHOT_CACHE_TTL_SECONDS)
    with _SPENDING_SNAPSHOT_CACHE_LOCK:
        _SPENDING_SNAPSHOT_CACHE[user_id] = {
            "value": snapshot,
            "expires_at": expires_at,
        }
    return snapshot


# ── Client summary sanitisation ──────────────────────────────────────

def _clamp_str(value, max_len: int) -> str:
    if not isinstance(value, str):
        return ""
    return value.strip()[:max_len]


def _to_float(value, default: float = 0.0) -> float:
    try:
        if isinstance(value, (int, float)):
            return float(value)
        return float(str(value))
    except Exception:
        return default


def sanitize_client_spending_summary(summary) -> dict | None:
    if not isinstance(summary, dict):
        return None

    cleaned: dict = {}
    cleaned["scope"] = _clamp_str(summary.get("scope", ""), 32)
    cleaned["generated_at"] = _clamp_str(summary.get("generated_at", ""), 40)
    window_days = int(_to_float(summary.get("window_days", 30), 30))
    cleaned["window_days"] = max(1, min(window_days, 90))

    totals = summary.get("totals")
    if isinstance(totals, dict):
        cleaned["totals"] = {
            "income_30d": max(0.0, _to_float(totals.get("income_30d", 0))),
            "expenses_30d": max(0.0, _to_float(totals.get("expenses_30d", 0))),
            "net_30d": _to_float(totals.get("net_30d", 0)),
        }

    cleaned_categories = []
    categories = summary.get("top_expense_categories")
    if isinstance(categories, list):
        for item in categories[:3]:
            if not isinstance(item, dict):
                continue
            name = _clamp_str(item.get("category", ""), 64)
            amount = max(0.0, _to_float(item.get("amount", 0)))
            if name:
                cleaned_categories.append({"category": name, "amount": amount})
    cleaned["top_expense_categories"] = cleaned_categories

    cleaned_recent = []
    recent = summary.get("recent_transactions")
    if isinstance(recent, list):
        for item in recent[:3]:
            if not isinstance(item, dict):
                continue
            date = _clamp_str(item.get("date", ""), 16)
            name = _clamp_str(item.get("name", ""), 80)
            category = _clamp_str(item.get("category", ""), 64)
            amount = _to_float(item.get("amount", 0))
            if name:
                cleaned_recent.append(
                    {"date": date, "name": name, "category": category, "amount": amount}
                )
    cleaned["recent_transactions"] = cleaned_recent

    cleaned_alerts = []
    alerts = summary.get("budget_alerts")
    if isinstance(alerts, list):
        for item in alerts[:3]:
            if not isinstance(item, dict):
                continue
            category = _clamp_str(item.get("category", ""), 64)
            spent = max(0.0, _to_float(item.get("spent", 0)))
            limit_val = max(0.0, _to_float(item.get("limit", 0)))
            ratio = max(0.0, _to_float(item.get("ratio", 0)))
            if category:
                cleaned_alerts.append(
                    {"category": category, "spent": spent, "limit": limit_val, "ratio": ratio}
                )
    cleaned["budget_alerts"] = cleaned_alerts

    has_signal = bool(
        cleaned.get("totals") or cleaned_categories or cleaned_recent or cleaned_alerts
    )
    return cleaned if has_signal else None


def format_client_summary_for_prompt(summary: dict) -> str:
    totals = summary.get("totals") or {}
    categories = summary.get("top_expense_categories") or []
    recent = summary.get("recent_transactions") or []
    alerts = summary.get("budget_alerts") or []

    cat_text = "\n".join(
        f"- {c['category']}: ${c['amount']:.2f}" for c in categories
    ) or "- none"
    recent_text = "\n".join(
        f"- {r['date']} | {r['name']} | ${abs(r['amount']):.2f}" for r in recent
    ) or "- none"
    alert_text = "\n".join(
        f"- {a['category']}: ${a['spent']:.2f}/${a['limit']:.2f}" for a in alerts
    ) or "- none"

    return (
        f"Income(30d): ${totals.get('income_30d', 0):.2f} | "
        f"Expenses: ${totals.get('expenses_30d', 0):.2f} | "
        f"Net: ${totals.get('net_30d', 0):.2f}\n"
        f"Top categories:\n{cat_text}\n"
        f"Recent:\n{recent_text}\n"
        f"Budget alerts:\n{alert_text}"
    )


# ── Prompt builder ───────────────────────────────────────────────────

SYSTEM_PROMPT = (
    "You are a concise personal finance assistant. "
    "Use the spending snapshot below. Be specific and practical. "
    "If data is missing, say so. Do not ask the user for data. "
    "Respond in the user's language.\n\n"
    "Output ONLY this JSON structure (no markdown fences):\n"
    '{"insights":["...","...","..."],"actions":["...","...","..."]}\n'
    "Each item must be one short sentence.\n\n"
)


def build_enhanced_prompt(spending_snapshot: str, context_source: str, user_prompt: str) -> str:
    return (
        f"{SYSTEM_PROMPT}"
        f"[SNAPSHOT ({context_source})]\n{spending_snapshot}\n\n"
        f"[QUESTION]\n{user_prompt}"
    )


BUDGET_SUGGEST_PROMPT = (
    "You are a concise personal finance assistant. "
    "Analyze the user's budget progress and spending data below. "
    "Respond in the user's language.\n\n"
    "Output ONLY this JSON (no markdown fences):\n"
    "{\n"
    '  "copy": "One-sentence overall budget health summary.",\n'
    '  "alerts": [{"category":"...","severity":"high|med|low","reason":"..."}],\n'
    '  "actions": [{"category":"...","type":"cut|monitor|increase","target":"$X/mo","why":"..."}]\n'
    "}\n"
    "Max 3 alerts, max 3 actions. Keep each field short.\n\n"
)


def build_budget_suggest_prompt(
    spending_snapshot: str,
    context_source: str,
    budget_progress: list[dict],
    view_mode: str,
) -> str:
    budget_lines = "\n".join(
        f"- {b.get('category','?')}: spent ${b.get('spent',0):.2f} / limit ${b.get('limit',0):.2f} (ratio {b.get('ratio',0):.2f})"
        for b in budget_progress[:15]
    ) or "- no budget data"

    return (
        f"{BUDGET_SUGGEST_PROMPT}"
        f"[SNAPSHOT ({context_source})]\n{spending_snapshot}\n\n"
        f"[BUDGET PROGRESS – {view_mode}]\n{budget_lines}\n"
    )


def sanitize_budget_progress(raw: list | None) -> list[dict]:
    """Validate and clamp the budget_progress list from the client."""
    if not isinstance(raw, list):
        return []
    result = []
    for item in raw[:30]:
        if not isinstance(item, dict):
            continue
        category = _clamp_str(item.get("category", ""), 64)
        if not category:
            continue
        result.append({
            "category": category,
            "spent": max(0.0, _to_float(item.get("spent", 0))),
            "limit": max(0.0, _to_float(item.get("limit", 0))),
            "ratio": max(0.0, _to_float(item.get("ratio", 0))),
        })
    return result
