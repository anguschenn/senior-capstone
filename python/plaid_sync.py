"""Plaid client initialisation, link-token creation, and transaction sync."""

import datetime as dt
import json
import time

import plaid
from plaid.model.products import Products
from plaid.model.country_code import CountryCode
from plaid.model.item_public_token_exchange_request import ItemPublicTokenExchangeRequest
from plaid.model.link_token_create_request import LinkTokenCreateRequest
from plaid.model.link_token_create_request_user import LinkTokenCreateRequestUser
from plaid.model.asset_report_create_request import AssetReportCreateRequest
from plaid.model.asset_report_create_request_options import AssetReportCreateRequestOptions
from plaid.model.asset_report_user import AssetReportUser
from plaid.model.asset_report_get_request import AssetReportGetRequest
from plaid.model.asset_report_pdf_get_request import AssetReportPDFGetRequest
from plaid.model.auth_get_request import AuthGetRequest
from plaid.model.transactions_sync_request import TransactionsSyncRequest
from plaid.model.accounts_balance_get_request import AccountsBalanceGetRequest
from plaid.model.accounts_get_request import AccountsGetRequest
from plaid.model.item_get_request import ItemGetRequest
from plaid.model.institutions_get_by_id_request import InstitutionsGetByIdRequest
from plaid.api import plaid_api

from config import (
    PLAID_CLIENT_ID,
    PLAID_SECRET,
    PLAID_ENV,
    PLAID_PRODUCTS,
    PLAID_COUNTRY_CODES,
    PLAID_REDIRECT_URI,
    DEMO_USER_ID,
    DEMO_PLAID_ITEM_ID,
)
from supabase_repo import supabase


class IdentityStateError(RuntimeError):
    DEMO_IDENTITY_MISSING = "demo_identity_missing"
    STORED_ITEM_NOT_FOUND = "stored_item_not_found"
    STORED_ACCESS_TOKEN_MISSING = "stored_access_token_missing"

    def __init__(self, reason: str, message: str):
        super().__init__(message)
        self.reason = reason

# ── Plaid client setup ───────────────────────────────────────────────

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

# ── Identity helpers ─────────────────────────────────────────────────


def require_demo_identity() -> tuple[str, str]:
    if not DEMO_USER_ID or not DEMO_PLAID_ITEM_ID:
        raise IdentityStateError(
            IdentityStateError.DEMO_IDENTITY_MISSING,
            "Missing DEMO_USER_ID or DEMO_PLAID_ITEM_ID. Set both in python/.env."
        )
    return DEMO_USER_ID, DEMO_PLAID_ITEM_ID


def get_stored_item_credentials() -> tuple[str, str]:
    user_id, plaid_item_id = require_demo_identity()
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
            "No stored plaid_items record for configured demo identity",
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


# ── Account & transaction sync ───────────────────────────────────────


def save_accounts_to_supabase(user_id: str, plaid_item_id: str, plaid_access_token: str) -> int:
    response = client.accounts_get(AccountsGetRequest(access_token=plaid_access_token)).to_dict()
    accounts = response.get("accounts", [])

    rows = []
    for a in accounts:
        balances = a.get("balances", {})
        rows.append(
            {
                "plaid_item_id": plaid_item_id,
                "user_id": user_id,
                "plaid_account_id": a.get("account_id"),
                "name": a.get("name"),
                "official_name": a.get("official_name"),
                "account_type": str(a.get("type", "")),
                "subtype": str(a.get("subtype", "")),
                "current_balance": balances.get("current"),
                "available_balance": balances.get("available"),
                "mask": a.get("mask"),
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
    except Exception as e:
        print(f"Could not retrieve cursor for user {user_id}: {type(e).__name__}: {e}")

    added, modified, removed = [], [], []
    has_more = True
    empty_cursor_retries = 0
    max_empty_cursor_retries = 5

    while has_more:
        sync_request = TransactionsSyncRequest(
            access_token=plaid_access_token, cursor=cursor
        )
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
        for t in added:
            pfc = t.get("personal_finance_category") or {}
            loc = t.get("location") or {}
            rows.append(
                {
                    "plaid_account_id": t.get("account_id"),
                    "user_id": user_id,
                    "plaid_transaction_id": t.get("transaction_id"),
                    "amount": t.get("amount"),
                    "date": str(t.get("date")),
                    "name": t.get("name"),
                    "merchant_name": t.get("merchant_name"),
                    "category": (t.get("category") or [None])[0],
                    "pfc_primary": pfc.get("primary"),
                    "pfc_detailed": pfc.get("detailed"),
                    "pfc_confidence": pfc.get("confidence_level"),
                    "pending": t.get("pending", False),
                    "location_city": loc.get("city"),
                    "location_region": loc.get("region"),
                    "location_lat": loc.get("lat"),
                    "location_lon": loc.get("lon"),
                }
            )
        supabase.table("transactions").upsert(
            rows, on_conflict="plaid_transaction_id"
        ).execute()

    for t in modified:
        pfc = t.get("personal_finance_category") or {}
        supabase.table("transactions").update(
            {
                "amount": t.get("amount"),
                "pending": t.get("pending"),
                "pfc_primary": pfc.get("primary"),
                "pfc_detailed": pfc.get("detailed"),
            }
        ).eq("plaid_transaction_id", t.get("transaction_id")).execute()

    for t in removed:
        supabase.table("transactions").delete().eq(
            "plaid_transaction_id", t.get("transaction_id")
        ).execute()

    supabase.table("plaid_items").update(
        {"cursor": cursor, "last_synced_at": dt.datetime.now().isoformat()}
    ).eq("id", plaid_item_id).eq("user_id", user_id).execute()

    return {"added": len(added), "modified": len(modified), "removed": len(removed)}


# ── Plaid utilities ──────────────────────────────────────────────────


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
        except plaid.ApiException as e:
            response = _safe_api_exception_body(e)
            if response.get("error_code") != "PRODUCT_NOT_READY":
                raise e
            retries_left -= 1
            if retries_left == 0:
                raise Exception("Ran out of retries while polling") from e
            time.sleep(ms / 1000)


def format_error(e):
    response = _safe_api_exception_body(e)
    return {
        "error": {
            "status_code": e.status,
            "display_message": response.get("error_message"),
            "error_code": response.get("error_code", "PLAID_API_ERROR"),
            "error_type": response.get("error_type", "API_ERROR"),
        }
    }


def pretty_print_response(response):
    print(json.dumps(response, indent=2, sort_keys=True, default=str))
