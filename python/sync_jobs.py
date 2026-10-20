"""Work that follows a transaction sync, shared by the app-triggered and webhook-triggered paths."""

import datetime as dt
import threading

import plaid

from ai import server_summary
from plaid_sync import _safe_api_exception_body, sync_transactions_to_supabase
from subscription_detector import detect_and_upsert_subscriptions
from supabase_repo import supabase
from user_model import refresh_user_model

# One lock per user_id so an app-triggered sync and a webhook-triggered sync for the
# same user never run detect_and_upsert_subscriptions at the same time. Without this,
# both can read "no existing row for this merchant yet" before either has inserted one,
# and each inserts its own copy — a duplicate subscription. Process-local, which is
# correct only because gunicorn runs a single worker (see CLAUDE.md), same as the
# per-item lock in plaid_sync.py.
_user_locks: dict[str, threading.Lock] = {}
_user_locks_guard = threading.Lock()


def _user_lock(user_id: str) -> threading.Lock:
    with _user_locks_guard:
        return _user_locks.setdefault(user_id, threading.Lock())


def record_sync(user_id: str, source: str) -> None:
    """Note a successful sync in sync_status, which the app reads on launch to decide
    whether it needs to sync at all. Never raises: a missing table (migration 012 not
    applied yet) only means the app keeps syncing on every launch, as before."""
    try:
        supabase.table("sync_status").upsert(
            {
                "user_id": user_id,
                "last_synced_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                "source": source,
            },
            on_conflict="user_id",
        ).execute()
    except Exception as error:
        print(f"sync_status write skipped for user {user_id}: {type(error).__name__}")


def run_post_sync(user_id: str, snapshot_service) -> None:
    """Refresh everything derived from transactions. Never raises.

    A second caller for the same user waits, then re-reads the transactions the
    first caller just wrote — never a duplicate detection pass on stale data.
    """
    snapshot_service.invalidate(user_id)
    server_summary.invalidate(user_id)
    with _user_lock(user_id):
        try:
            sub_stats = detect_and_upsert_subscriptions(user_id)
            print(f"Subscription detection for user {user_id}: {sub_stats}")
        except Exception as sub_error:
            print(f"Subscription detection warning for user {user_id}: {sub_error}")
        # Stats, alerts and suggestions (migration 014). Never raises.
        model = refresh_user_model(user_id)
        print(
            f"User model for user {user_id}: stats={model['stats']} "
            f"alerts={model['alerts']} suggestions={model['suggestions']}"
        )
    warm_chat_summary(user_id, model["tx_rows"])


def warm_chat_summary(user_id: str, tx_rows: list[dict]) -> None:
    """Build the all-accounts, this-month chat summary now, from the rows just read, so the
    next chat question doesn't wait for it. Never raises."""
    if not tx_rows:
        return
    try:
        context = server_summary.parse_context({"today": dt.date.today().isoformat()})
        server_summary.summary_for(user_id, context, tx_rows=tx_rows)
    except Exception as error:
        print(f"chat summary warm-up skipped for user {user_id}: {type(error).__name__}")


def sync_item_from_webhook(plaid_item_id: str, snapshot_service) -> None:
    """Background job for SYNC_UPDATES_AVAILABLE. plaid_item_id is Plaid's item_id string."""
    try:
        rows = (
            supabase.table("plaid_items")
            .select("id,user_id,access_token")
            .eq("item_id", plaid_item_id)
            .limit(1)
            .execute()
        ).data
        if not rows or not rows[0].get("access_token"):
            print(f"[plaid-webhook] no stored item for item_id={plaid_item_id}; ignoring")
            return
        row = rows[0]
        stats = sync_transactions_to_supabase(row["user_id"], row["id"], row["access_token"])
        print(f"[plaid-webhook] synced item_id={plaid_item_id}: {stats}")
        record_sync(row["user_id"], "webhook")
        if any(stats.values()):
            run_post_sync(row["user_id"], snapshot_service)
    except plaid.ApiException as error:
        code = _safe_api_exception_body(error).get("error_code", "PLAID_API_ERROR")
        print(f"[plaid-webhook] sync failed for item_id={plaid_item_id}: {code}")
    except Exception as error:
        print(f"[plaid-webhook] sync failed for item_id={plaid_item_id}: {type(error).__name__}")
