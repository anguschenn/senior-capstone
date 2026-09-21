"""Detect recurring charges from transaction history and sync to subscriptions table."""

import datetime as dt
import re
from collections import defaultdict

from supabase_repo import supabase

_WEEKLY_MIN = 5
_WEEKLY_MAX = 9
_MONTHLY_MIN = 25
_MONTHLY_MAX = 37
_ANNUAL_MIN = 350
_ANNUAL_MAX = 380
_MIN_OCCURRENCES = 2
_AMOUNT_TOLERANCE = 0.10
_INTERVAL_TOLERANCE = 0.30
_TX_FETCH_LIMIT = 2000

# Grace window (days) before a missed renewal marks a subscription inactive.
_GRACE_DAYS = {"weekly": 3, "monthly": 7, "annual": 14}

# Normalized merchant names that are unambiguously subscription services.
# Everything NOT in this set will be flagged for user confirmation.
_KNOWN_SUBSCRIPTION_MERCHANTS = {
    # Music & podcasts
    "spotify", "apple music", "tidal", "deezer", "youtube music", "amazon music",
    # Video streaming
    "netflix", "hulu", "disney", "hbo max", "apple tv", "peacock", "paramount",
    "youtube premium", "amazon prime", "crunchyroll", "mubi",
    # AI & software
    "openai", "claude ai", "anthropic", "github", "github copilot",
    "adobe", "microsoft", "google one", "google workspace",
    "dropbox", "notion", "figma", "canva", "slack", "zoom", "loom",
    "1password", "lastpass", "dashlane", "nordvpn", "expressvpn",
    # Fitness & health
    "puregym", "planet fitness", "peloton", "strava", "myfitnesspal",
    "calm", "headspace", "noom",
    # Gaming
    "xbox", "playstation", "nintendo", "ea play", "ubisoft",
    # News & reading
    "new york times", "washington post", "the guardian", "medium",
    "kindle unlimited", "audible",
    # Utilities & finance
    "icloud", "google drive", "onedrive", "amazon web services", "aws",
}


def _normalize_merchant(name):
    name = (name or "").strip().lower()
    name = re.sub(r"\s*(inc\.?|llc\.?|ltd\.?|corp\.?|co\.?|\.com)$", "", name)
    name = re.sub(r"[^\w\s]", " ", name)
    name = re.sub(r"\s+", " ", name).strip()
    return name


def _classify_interval(avg_days):
    if _WEEKLY_MIN <= avg_days <= _WEEKLY_MAX:
        return "weekly"
    if _MONTHLY_MIN <= avg_days <= _MONTHLY_MAX:
        return "monthly"
    if _ANNUAL_MIN <= avg_days <= _ANNUAL_MAX:
        return "annual"
    return None


def _next_charge_date(last_date, frequency):
    if frequency == "weekly":
        return last_date + dt.timedelta(days=7)
    if frequency == "annual":
        try:
            return last_date.replace(year=last_date.year + 1)
        except ValueError:
            return last_date + dt.timedelta(days=365)
    return last_date + dt.timedelta(days=30)


def _needs_confirmation(norm_merchant, pfc_detailed_list):
    """
    Return False (auto-confirm) only for known subscription merchants.
    Everything else is flagged for user confirmation.
    PFC subscription detail overrides unknown merchant as a secondary signal.
    """
    if norm_merchant in _KNOWN_SUBSCRIPTION_MERCHANTS:
        return False
    for detailed in pfc_detailed_list:
        if detailed and "subscription" in detailed.lower():
            return False
    return True


def _account_segments(charges):
    """
    Collapse a chronologically-sorted charge list into contiguous
    (account_id, first_date, last_date) runs — one entry per unbroken
    stretch of charges on the same billing account.
    """
    segments = []
    for charge_date, _amount, _raw, _pfc_p, _pfc_d, account_id in charges:
        account_id = account_id or None
        if segments and segments[-1]["account_id"] == account_id:
            segments[-1]["last_date"] = charge_date
        else:
            segments.append({
                "account_id": account_id,
                "first_date": charge_date,
                "last_date": charge_date,
            })
    return segments


def _detect_from_rows(tx_rows, today=None):
    """Return subscription candidates detected from raw transaction rows."""
    today = today or dt.date.today()
    groups = defaultdict(list)
    for tx in tx_rows:
        raw_merchant = tx.get("merchant_name") or tx.get("name") or ""
        norm = _normalize_merchant(raw_merchant)
        if not norm:
            continue
        account_id = (tx.get("plaid_account_id") or "").strip()
        try:
            charge_date = dt.date.fromisoformat(tx.get("date") or "")
        except ValueError:
            continue
        try:
            amount = float(tx.get("amount") or 0)
        except (TypeError, ValueError):
            continue
        if amount <= 0:
            continue
        groups[norm].append((
            charge_date,
            amount,
            raw_merchant.strip(),
            (tx.get("pfc_primary") or "").strip(),
            (tx.get("pfc_detailed") or "").strip(),
            account_id,
        ))

    candidates = []
    for norm_merchant, charges in groups.items():
        if len(charges) < _MIN_OCCURRENCES:
            continue
        charges.sort(key=lambda c: c[0])
        dates = [c[0] for c in charges]
        amounts = [c[1] for c in charges]

        intervals = [(dates[i + 1] - dates[i]).days for i in range(len(dates) - 1)]
        avg_interval = sum(intervals) / len(intervals)
        if avg_interval <= 0:
            continue

        frequency = _classify_interval(avg_interval)
        if not frequency:
            continue

        if any(abs(d - avg_interval) > avg_interval * _INTERVAL_TOLERANCE for d in intervals):
            continue

        avg_amount = sum(amounts) / len(amounts)
        if avg_amount <= 0:
            continue
        if any(abs(a - avg_amount) > avg_amount * _AMOUNT_TOLERANCE for a in amounts):
            continue

        next_charge_date = _next_charge_date(dates[-1], frequency)
        grace = _GRACE_DAYS.get(frequency, 7)
        if today > next_charge_date + dt.timedelta(days=grace):
            # The most recent charge is already past its renewal + grace
            # window — this pattern is historically clean but no longer
            # current. Don't resurrect it as "active"; let
            # _mark_stale_subscriptions retire the existing row instead.
            continue

        pfc_detaileds = [c[4] for c in charges]

        candidates.append({
            # Most recent charge's account — the merchant/user identity is
            # what defines a subscription, not which account currently bills it
            # (a card-on-file switch shouldn't split one subscription in two).
            "account_id": charges[-1][5] or None,
            "norm_merchant": norm_merchant,
            "merchant_name": charges[-1][2] or norm_merchant,
            "amount": round(avg_amount, 2),
            "frequency": frequency,
            "next_charge_date": next_charge_date.isoformat(),
            "needs_confirmation": _needs_confirmation(norm_merchant, pfc_detaileds),
            "account_segments": _account_segments(charges),
        })
    return candidates


def _mark_stale_subscriptions(user_id, tx_rows):
    """
    Mark active subscriptions inactive when their expected renewal window
    has passed without a matching transaction appearing.
    Returns the number of subscriptions deactivated.
    """
    today = dt.date.today()

    active_resp = (
        supabase.table("subscriptions")
        .select("id,merchant_name,frequency,next_charge_date")
        .eq("user_id", user_id)
        .eq("is_active", True)
        .execute()
    )

    # Build a quick lookup: (norm_merchant, date). Deliberately not scoped to
    # account_id — a subscription that switches accounts (e.g. card on file
    # changes) is still the same subscription, and shouldn't look stale on
    # its old account.
    tx_lookup = set()
    for tx in tx_rows:
        norm = _normalize_merchant(tx.get("merchant_name") or tx.get("name") or "")
        try:
            tx_date = dt.date.fromisoformat(tx.get("date") or "")
            tx_lookup.add((norm, tx_date))
        except ValueError:
            pass

    deactivated = 0
    for sub in (active_resp.data or []):
        try:
            expected = dt.date.fromisoformat(sub.get("next_charge_date") or "")
        except ValueError:
            continue

        frequency = sub.get("frequency") or "monthly"
        grace = _GRACE_DAYS.get(frequency, 7)

        # Only act once we're past the grace period
        if today <= expected + dt.timedelta(days=grace):
            continue

        norm_merchant = _normalize_merchant(sub.get("merchant_name") or "")
        window_start = expected - dt.timedelta(days=grace)
        window_end = expected + dt.timedelta(days=grace)

        found = any(
            nm == norm_merchant
            and window_start <= d <= window_end
            for (nm, d) in tx_lookup
        )

        if not found:
            supabase.table("subscriptions").update(
                {"is_active": False}
            ).eq("id", sub["id"]).execute()
            deactivated += 1

    return deactivated


def _sync_account_history(subscription_id, segments):
    """
    Record which billing account(s) a subscription has used over time.
    The most recent segment is left open (to_date=None) to mean "still
    billing here"; earlier segments are closed off with their last known
    charge date. Idempotent via the (subscription_id, plaid_account_id,
    from_date) unique constraint, so re-running a sync just no-ops on
    unchanged segments.
    """
    if not segments:
        return
    last_index = len(segments) - 1
    rows = [
        {
            "subscription_id": subscription_id,
            "plaid_account_id": seg["account_id"],
            "from_date": seg["first_date"].isoformat(),
            "to_date": None if i == last_index else seg["last_date"].isoformat(),
        }
        for i, seg in enumerate(segments)
    ]
    supabase.table("subscription_account_history").upsert(
        rows, on_conflict="subscription_id,plaid_account_id,from_date"
    ).execute()


def detect_and_upsert_subscriptions(user_id):
    """
    Main entry: detect recurring charges, mark stale ones inactive, and
    sync results to the subscriptions table.

    Existing rows matched by normalized merchant name (per user) are updated
    in-place. User-confirmed rows (needs_confirmation=False) keep their
    confirmation status even if re-detected as ambiguous.

    Returns {"detected", "inserted", "updated", "deactivated"}.
    """
    rows_resp = (
        supabase.table("transactions")
        .select("plaid_account_id,merchant_name,name,amount,date,pfc_primary,pfc_detailed")
        .eq("user_id", user_id)
        .eq("pending", False)
        .gt("amount", 0)
        .order("date", desc=True)
        .limit(_TX_FETCH_LIMIT)
        .execute()
    )
    tx_rows = rows_resp.data or []

    candidates = _detect_from_rows(tx_rows)

    if not candidates:
        deactivated = _mark_stale_subscriptions(user_id, tx_rows)
        return {"detected": 0, "inserted": 0, "updated": 0, "deactivated": deactivated}

    existing_resp = (
        supabase.table("subscriptions")
        .select("id,merchant_name,user_confirmed")
        .eq("user_id", user_id)
        .execute()
    )
    existing_by_key = {}
    user_confirmed_keys = set()
    for row in (existing_resp.data or []):
        key = _normalize_merchant(row.get("merchant_name") or "")
        existing_by_key[key] = row["id"]
        # user_confirmed=True means the user explicitly clicked "Yes, subscription"
        if row.get("user_confirmed") is True:
            user_confirmed_keys.add(key)

    inserted = 0
    updated = 0
    for sub in candidates:
        lookup_key = sub["norm_merchant"]

        if lookup_key in existing_by_key:
            update_data = {
                "amount": sub["amount"],
                "frequency": sub["frequency"],
                "next_charge_date": sub["next_charge_date"],
                "is_active": True,
            }
            if lookup_key not in user_confirmed_keys:
                update_data["needs_confirmation"] = sub["needs_confirmation"]
            subscription_id = existing_by_key[lookup_key]
            supabase.table("subscriptions").update(update_data).eq(
                "id", subscription_id
            ).execute()
            _sync_account_history(subscription_id, sub["account_segments"])
            updated += 1
        else:
            insert_resp = (
                supabase.table("subscriptions")
                .insert(
                    {
                        "user_id": user_id,
                        "plaid_account_id": sub["account_id"],
                        "merchant_name": sub["merchant_name"],
                        "amount": sub["amount"],
                        "frequency": sub["frequency"],
                        "next_charge_date": sub["next_charge_date"],
                        "is_active": True,
                        "needs_confirmation": sub["needs_confirmation"],
                    }
                )
                .execute()
            )
            new_id = (insert_resp.data or [{}])[0].get("id")
            if new_id:
                _sync_account_history(new_id, sub["account_segments"])
            inserted += 1

    deactivated = _mark_stale_subscriptions(user_id, tx_rows)

    return {
        "detected": len(candidates),
        "inserted": inserted,
        "updated": updated,
        "deactivated": deactivated,
    }
