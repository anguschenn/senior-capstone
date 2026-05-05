"""Plaid client initialisation, link-token creation, and transaction sync."""

import datetime as dt
import json
import time

import plaid
from plaid.api import plaid_api
from plaid.model.accounts_get_request import AccountsGetRequest
from plaid.model.products import Products
from plaid.model.transactions_sync_request import TransactionsSyncRequest

from config import (
    PLAID_CLIENT_ID,
    PLAID_ENV,
    PLAID_PRODUCTS,
    PLAID_SECRET,
)
from supabase_repo import supabase


class IdentityStateError(RuntimeError):
    STORED_ITEM_NOT_FOUND = "stored_item_not_found"
    STORED_ACCESS_TOKEN_MISSING = "stored_access_token_missing"

    def __init__(self, reason: str, message: str):
        super().__init__(message)
        self.reason = reason


host = plaid.Environment.Sandbox
if PLAID_ENV == "production":
    host = plaid.Environment.Production

configuration = plaid.Configuration(
    host=host,
    api_key={
        "clientId": PLAID_CLIENT_ID,
        "secret": PLAID_SECRET,
        "plaidVersion": "2020-09-14",
    },
)

api_client = plaid.ApiClient(configuration)
client = plaid_api.PlaidApi(api_client)
products = [Products(p) for p in PLAID_PRODUCTS]


def get_stored_item_credentials(user_id: str, plaid_item_id: str) -> tuple[str, str]:
    row = (
        supabase.table("plaid_items")
        .select("access_token,item_id")
        .eq("id", plaid_item_id)
        .eq("user_id", user_id)
        .limit(1)
        .execute()
    )
    if not row.data:
        raise IdentityStateError(
            IdentityStateError.STORED_ITEM_NOT_FOUND,
            "No stored plaid_items record for current user",
        )
    record = row.data[0]
    access_token = record.get("access_token")
    item_id = record.get("item_id")
    if not access_token:
        raise IdentityStateError(
            IdentityStateError.STORED_ACCESS_TOKEN_MISSING,
            "Stored Plaid access token is missing",
        )
    return access_token, item_id


def save_accounts_to_supabase(
    user_id: str, plaid_item_id: str, plaid_access_token: str
) -> int:
    response = client.accounts_get(
        AccountsGetRequest(access_token=plaid_access_token)
    ).to_dict()
    accounts = response.get("accounts", [])

    rows = []
    for account in accounts:
        balances = account.get("balances", {})
        rows.append(
            {
                "plaid_item_id": plaid_item_id,
                "user_id": user_id,
                "plaid_account_id": account.get("account_id"),
                "name": account.get("name"),
                "official_name": account.get("official_name"),
                "account_type": str(account.get("type", "")),
                "subtype": str(account.get("subtype", "")),
                "current_balance": balances.get("current"),
                "available_balance": balances.get("available"),
                "mask": account.get("mask"),
                "updated_at": dt.datetime.now().isoformat(),
            }
        )

    if rows:
        supabase.table("accounts").upsert(rows, on_conflict="plaid_account_id").execute()
    return len(rows)


def sync_transactions_to_supabase(
    user_id: str, plaid_item_id: str, plaid_access_token: str
) -> dict:
    cursor = ""
    try:
        item_row = (
            supabase.table("plaid_items")
            .select("cursor")
            .eq("id", plaid_item_id)
            .eq("user_id", user_id)
            .execute()
        )
        if item_row.data and item_row.data[0].get("cursor"):
            cursor = item_row.data[0]["cursor"]
    except Exception as error:
        print(f"Could not retrieve cursor for user {user_id}: {type(error).__name__}: {error}")

    added, modified, removed = [], [], []
    has_more = True
    empty_cursor_retries = 0
    max_empty_cursor_retries = 5

    while has_more:
        sync_request = TransactionsSyncRequest(access_token=plaid_access_token, cursor=cursor)
        response = client.transactions_sync(sync_request).to_dict()
        cursor = response["next_cursor"]
        if cursor == "":
            empty_cursor_retries += 1
            if empty_cursor_retries >= max_empty_cursor_retries:
                raise RuntimeError("transactions_sync returned empty next_cursor repeatedly")
            time.sleep(2)
            continue
        empty_cursor_retries = 0
        added.extend(response["added"])
        modified.extend(response["modified"])
        removed.extend(response["removed"])
        has_more = response["has_more"]

    if added:
        rows = []
        for transaction in added:
            pfc = transaction.get("personal_finance_category") or {}
            loc = transaction.get("location") or {}
            rows.append(
                {
                    "plaid_account_id": transaction.get("account_id"),
                    "user_id": user_id,
                    "plaid_transaction_id": transaction.get("transaction_id"),
                    "amount": transaction.get("amount"),
                    "date": str(transaction.get("date")),
                    "name": transaction.get("name"),
                    "merchant_name": transaction.get("merchant_name"),
                    "category": (transaction.get("category") or [None])[0],
                    "pfc_primary": pfc.get("primary"),
                    "pfc_detailed": pfc.get("detailed"),
                    "pfc_confidence": pfc.get("confidence_level"),
                    "pending": transaction.get("pending", False),
                    "location_city": loc.get("city"),
                    "location_region": loc.get("region"),
                    "location_lat": loc.get("lat"),
                    "location_lon": loc.get("lon"),
                }
            )
        supabase.table("transactions").upsert(rows, on_conflict="plaid_transaction_id").execute()

    for transaction in modified:
        pfc = transaction.get("personal_finance_category") or {}
        supabase.table("transactions").update(
            {
                "amount": transaction.get("amount"),
                "pending": transaction.get("pending"),
                "pfc_primary": pfc.get("primary"),
                "pfc_detailed": pfc.get("detailed"),
            }
        ).eq("plaid_transaction_id", transaction.get("transaction_id")).execute()

    for transaction in removed:
        supabase.table("transactions").delete().eq(
            "plaid_transaction_id", transaction.get("transaction_id")
        ).execute()

    supabase.table("plaid_items").update(
        {"cursor": cursor, "last_synced_at": dt.datetime.now().isoformat()}
    ).eq("id", plaid_item_id).eq("user_id", user_id).execute()

    return {"added": len(added), "modified": len(modified), "removed": len(removed)}


def _safe_api_exception_body(error: plaid.ApiException) -> dict:
    body = {}
    raw_body = getattr(error, "body", None)
    if isinstance(raw_body, str):
        try:
            parsed = json.loads(raw_body)
            if isinstance(parsed, dict):
                body = parsed
        except Exception:
            body = {}
    return body


def poll_with_retries(request_callback, ms=1000, retries_left=20):
    while retries_left > 0:
        try:
            return request_callback()
        except plaid.ApiException as error:
            response = _safe_api_exception_body(error)
            if response.get("error_code") != "PRODUCT_NOT_READY":
                raise error
            retries_left -= 1
            if retries_left == 0:
                raise Exception("Ran out of retries while polling") from error
            time.sleep(ms / 1000)


def format_error(error):
    response = _safe_api_exception_body(error)
    return {
        "error": {
            "status_code": error.status,
            "display_message": response.get("error_message"),
            "error_code": response.get("error_code", "PLAID_API_ERROR"),
            "error_type": response.get("error_type", "API_ERROR"),
        }
    }


def pretty_print_response(response):
    print(json.dumps(response, indent=2, sort_keys=True, default=str))
