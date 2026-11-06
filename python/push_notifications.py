"""Persist and deliver opt-in browser push notifications."""

import base64
import datetime as dt
import json
import logging
from urllib.parse import urlparse

from pywebpush import WebPushException, webpush

from budget_progress import (
    classify_by_pfc_signals,
    classify_rows,
    fetch_decisions,
    is_p2p_inflow,
    user_category_for_row,
)
from config import (
    PUSH_VAPID_PRIVATE_KEY,
    PUSH_VAPID_PUBLIC_KEY,
    PUSH_VAPID_SUBJECT,
)
from supabase_repo import supabase
from user_model import fetch_all_transactions, fetch_rules

logger = logging.getLogger(__name__)
_MAX_SUBSCRIPTIONS_PER_USER = 20
_MAX_PENDING_DELIVERIES = 50
_MAX_DELIVERY_ATTEMPTS = 5
_CLAIM_TIMEOUT = dt.timedelta(minutes=5)


def push_enabled() -> bool:
    return bool(PUSH_VAPID_PUBLIC_KEY and PUSH_VAPID_PRIVATE_KEY and PUSH_VAPID_SUBJECT)


def public_push_config() -> dict:
    return {
        "enabled": push_enabled(),
        "vapid_public_key": PUSH_VAPID_PUBLIC_KEY if push_enabled() else None,
    }


def validate_push_subscription(subscription: object) -> dict:
    """Validate a Chrome subscription before it is stored or used for outbound requests."""
    if not isinstance(subscription, dict):
        raise ValueError("A browser push subscription is required.")
    endpoint = subscription.get("endpoint")
    keys = subscription.get("keys")
    if not isinstance(endpoint, str) or len(endpoint) > 2048:
        raise ValueError("The push endpoint is invalid.")
    parsed = urlparse(endpoint)
    if (
        parsed.scheme != "https"
        or parsed.hostname != "fcm.googleapis.com"
        or not parsed.path.startswith("/fcm/send/")
        or parsed.username
        or parsed.password
    ):
        raise ValueError("Only Chrome push endpoints are supported.")
    if not isinstance(keys, dict):
        raise ValueError("The push encryption keys are missing.")
    p256dh = keys.get("p256dh")
    auth = keys.get("auth")
    if not isinstance(p256dh, str) or not isinstance(auth, str):
        raise ValueError("The push encryption keys are invalid.")
    decoded_p256dh = _decode_base64url(p256dh)
    if decoded_p256dh is None or len(decoded_p256dh) != 65:
        raise ValueError("The push public key is invalid.")
    decoded_auth = _decode_base64url(auth)
    if decoded_auth is None or len(decoded_auth) != 16:
        raise ValueError("The push authentication key is invalid.")
    return {"endpoint": endpoint, "p256dh": p256dh, "auth": auth}


def _decode_base64url(value: str) -> bytes | None:
    try:
        return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except (ValueError, TypeError):
        return None


def save_subscription(user_id: str, subscription: object) -> None:
    validated = validate_push_subscription(subscription)
    now = _now_iso()
    supabase.table("push_subscriptions").upsert(
        {
            "user_id": user_id,
            **validated,
            "updated_at": now,
        },
        on_conflict="endpoint",
    ).execute()


def remove_subscription(user_id: str, endpoint: str) -> None:
    if not isinstance(endpoint, str) or not endpoint or len(endpoint) > 2048:
        raise ValueError("The push endpoint is invalid.")
    supabase.table("push_subscriptions").delete().eq("user_id", user_id).eq(
        "endpoint", endpoint
    ).execute()


def _now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def _queue_event(user_id: str, event: dict) -> None:
    if not push_enabled():
        return
    supabase.table("notification_deliveries").upsert(
        {
            "user_id": user_id,
            "event_key": event["event_key"],
            "kind": event["kind"],
            "title": event["title"],
            "body": event["body"],
            "url": event["url"],
            "status": "pending",
        },
        on_conflict="user_id,event_key",
        ignore_duplicates=True,
    ).execute()


def _budget_event(event: dict) -> dict:
    return {
        **event,
        "title": "SmartSpend budget alert",
        "body": "A budget needs your attention. Open SmartSpend to review it.",
    }


def _pending_budget_events(user_id: str) -> list[dict]:
    rows = (
        supabase.table("budget_alerts")
        .select("month,category_id,kind,first_detected_at")
        .eq("user_id", user_id)
        .is_("resolved_at", "null")
        .is_("notified_at", "null")
        .limit(500)
        .execute()
    ).data or []
    events = []
    for row in rows:
        month = str(row.get("month") or "")
        category_id = str(row.get("category_id") or "")
        kind = str(row.get("kind") or "")
        detected_at = str(row.get("first_detected_at") or "")
        if not month or not category_id or not kind or not detected_at:
            continue
        events.append(
            _budget_event(
                {
                    "event_key": (f"budget:{month}:{category_id}:{kind}:{detected_at}"),
                    "kind": "budget_alert",
                    "url": "/?notification=budget",
                }
            )
        )
    return events


def _mark_budget_alert_notified(user_id: str, event_key: str) -> None:
    parts = event_key.split(":", 4)
    if len(parts) != 5 or parts[0] != "budget":
        return
    _, month, category_id, kind, detected_at = parts
    (
        supabase.table("budget_alerts")
        .update({"notified_at": _now_iso()})
        .eq("user_id", user_id)
        .eq("month", month)
        .eq("category_id", category_id)
        .eq("kind", kind)
        .eq("first_detected_at", detected_at)
        .is_("resolved_at", "null")
        .execute()
    )


def _pending_subscription_events(user_id: str) -> list[dict]:
    rows = (
        supabase.table("subscriptions")
        .select("id")
        .eq("user_id", user_id)
        .eq("is_active", True)
        .eq("needs_confirmation", True)
        .limit(500)
        .execute()
    ).data or []
    return [
        {
            "event_key": f"subscription-review:{row['id']}",
            "kind": "subscription_review",
            "title": "SmartSpend needs your input",
            "body": "A recurring charge needs your review.",
            "url": "/?notification=subscription_review",
        }
        for row in rows
        if row.get("id")
    ]


def pending_transaction_review_events(user_id: str) -> list[dict]:
    """Mirror the app's low-confidence review rule, excluding saved user decisions."""
    rows = fetch_all_transactions(user_id)
    rules = fetch_rules(user_id)
    decisions = fetch_decisions(user_id)
    kinds = classify_rows(rows, rules, decisions=decisions)
    events = []
    for row in rows:
        transaction_id = str(row.get("plaid_transaction_id") or "").strip()
        if not transaction_id or user_category_for_row(row, rules, decisions):
            continue
        kind = kinds.get(transaction_id)
        if kind and kind.kind in {"internal", "payback"}:
            continue
        if is_p2p_inflow(row):
            continue
        category, confidence = classify_by_pfc_signals(
            str(row.get("pfc_primary") or "").strip(),
            str(row.get("pfc_detailed") or row.get("category") or "").strip(),
            str(row.get("name") or row.get("merchant_name") or "").strip(),
            str(row.get("name") or "").strip(),
        )
        if confidence != "low" and category != "Other":
            continue
        events.append(
            {
                "event_key": f"transaction-review:{transaction_id}",
                "kind": "transaction_review",
                "title": "SmartSpend needs your input",
                "body": "A transaction needs a category review.",
                "url": "/?notification=transaction_review",
            }
        )
    return events


def process_user_notifications(user_id: str, new_budget_events: list[dict] | None = None) -> None:
    """Queue new state changes and deliver queued events for one authenticated user."""
    if not push_enabled():
        return
    events = [_budget_event(event) for event in (new_budget_events or [])]
    events.extend(_pending_budget_events(user_id))
    events.extend(_pending_subscription_events(user_id))
    events.extend(pending_transaction_review_events(user_id))
    for event in {event["event_key"]: event for event in events}.values():
        _queue_event(user_id, event)
    dispatch_pending_notifications(user_id)


def _send_to_subscription(subscription: dict, payload: str) -> tuple[bool, bool]:
    """Return (delivered, permanently_invalid)."""
    try:
        webpush(
            subscription_info={
                "endpoint": subscription["endpoint"],
                "keys": {
                    "p256dh": subscription["p256dh"],
                    "auth": subscription["auth"],
                },
            },
            data=payload,
            vapid_private_key=PUSH_VAPID_PRIVATE_KEY,
            vapid_claims={"sub": PUSH_VAPID_SUBJECT},
            ttl=3600,
            timeout=5,
        )
        return True, False
    except WebPushException as error:
        status = getattr(getattr(error, "response", None), "status_code", None)
        if status in {404, 410}:
            return False, True
        logger.warning("Web push failed with HTTP status %s", status or "unknown")
        return False, False
    except Exception as error:
        logger.warning("Web push failed: %s", type(error).__name__)
        return False, False


def dispatch_pending_notifications(user_id: str) -> None:
    """Deliver queued events once to the user's active Chrome subscriptions."""
    if not push_enabled():
        return
    subscriptions = (
        supabase.table("push_subscriptions")
        .select("id,endpoint,p256dh,auth")
        .eq("user_id", user_id)
        .order("created_at")
        .limit(_MAX_SUBSCRIPTIONS_PER_USER)
        .execute()
    ).data or []
    if not subscriptions:
        return

    stale_before = (dt.datetime.now(dt.timezone.utc) - _CLAIM_TIMEOUT).isoformat()
    supabase.table("notification_deliveries").update({"status": "pending", "claimed_at": None}).eq(
        "user_id", user_id
    ).eq("status", "sending").lt("claimed_at", stale_before).execute()

    deliveries = (
        supabase.table("notification_deliveries")
        .select("id,event_key,title,body,url,attempts")
        .eq("user_id", user_id)
        .eq("status", "pending")
        .order("created_at")
        .limit(_MAX_PENDING_DELIVERIES)
        .execute()
    ).data or []
    for delivery in deliveries:
        attempts = int(delivery.get("attempts") or 0) + 1
        claimed = (
            supabase.table("notification_deliveries")
            .update(
                {
                    "status": "sending",
                    "claimed_at": _now_iso(),
                    "attempts": attempts,
                    "last_error": None,
                }
            )
            .eq("id", delivery["id"])
            .eq("status", "pending")
            .select("id")
            .execute()
        ).data or []
        if not claimed:
            continue

        payload = json.dumps(
            {
                "title": delivery["title"],
                "body": delivery["body"],
                "url": delivery["url"],
                "tag": str(delivery["id"]),
            }
        )
        delivered = False
        invalid_ids = []
        for subscription in subscriptions:
            ok, invalid = _send_to_subscription(subscription, payload)
            delivered = delivered or ok
            if invalid:
                invalid_ids.append(subscription["id"])
        for subscription_id in invalid_ids:
            supabase.table("push_subscriptions").delete().eq("id", subscription_id).eq(
                "user_id", user_id
            ).execute()

        if delivered:
            supabase.table("notification_deliveries").update(
                {"status": "sent", "sent_at": _now_iso(), "claimed_at": None}
            ).eq("id", delivery["id"]).execute()
            if delivery.get("event_key"):
                _mark_budget_alert_notified(user_id, delivery["event_key"])
        elif attempts >= _MAX_DELIVERY_ATTEMPTS:
            supabase.table("notification_deliveries").update(
                {
                    "status": "failed",
                    "claimed_at": None,
                    "last_error": "Push delivery failed after maximum attempts",
                }
            ).eq("id", delivery["id"]).execute()
        else:
            supabase.table("notification_deliveries").update(
                {
                    "status": "pending",
                    "claimed_at": None,
                    "last_error": "No active push endpoint accepted the notification",
                }
            ).eq("id", delivery["id"]).execute()
