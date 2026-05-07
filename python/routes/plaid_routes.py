"""Plaid and transaction-related API routes."""

import base64
import time

import plaid
from flask import Blueprint, current_app, jsonify, request
from plaid.model.accounts_balance_get_request import AccountsBalanceGetRequest
from plaid.model.accounts_get_request import AccountsGetRequest
from plaid.model.asset_report_create_request import AssetReportCreateRequest
from plaid.model.asset_report_create_request_options import AssetReportCreateRequestOptions
from plaid.model.asset_report_get_request import AssetReportGetRequest
from plaid.model.asset_report_pdf_get_request import AssetReportPDFGetRequest
from plaid.model.asset_report_user import AssetReportUser
from plaid.model.auth_get_request import AuthGetRequest
from plaid.model.country_code import CountryCode
from plaid.model.institutions_get_by_id_request import InstitutionsGetByIdRequest
from plaid.model.item_get_request import ItemGetRequest
from plaid.model.item_public_token_exchange_request import ItemPublicTokenExchangeRequest
from plaid.model.link_token_create_request import LinkTokenCreateRequest
from plaid.model.link_token_create_request_user import LinkTokenCreateRequestUser

from api.http_helpers import identity_error_response, log_route_error, plaid_error_response
from auth import UserAuthError, require_supabase_user_id
from config import (
    PLAID_COUNTRY_CODES,
    PLAID_ENV,
    PLAID_PRODUCTS,
    PLAID_REDIRECT_URI,
)
from plaid_sync import (
    IdentityStateError,
    client,
    get_stored_item_credentials,
    poll_with_retries,
    pretty_print_response,
    products,
    save_accounts_to_supabase,
    sync_transactions_to_supabase,
)
from supabase_repo import supabase

plaid_bp = Blueprint("plaid", __name__)
RECENT_TRANSACTIONS_LIMIT = 20


def _load_recent_transactions(user_id: str, limit: int = RECENT_TRANSACTIONS_LIMIT):
    return (
        supabase.table("transactions")
        .select("*")
        .eq("user_id", user_id)
        .order("date", desc=True)
        .limit(limit)
        .execute()
    )


@plaid_bp.route("/api/info", methods=["GET"])
def info():
    has_configured_identity = True
    payload = {
        "products": PLAID_PRODUCTS,
        "plaid_env": PLAID_ENV,
        "has_configured_identity": has_configured_identity,
        "has_stored_item": False,
    }

    if not has_configured_identity:
        payload["identity_status"] = "not_configured"
        return jsonify(payload), 200

    try:
        user_id = require_supabase_user_id()
        items = supabase.table("plaid_items").select("id").eq("user_id", user_id).limit(1).execute()
        if not items.data:
            raise IdentityStateError(IdentityStateError.STORED_ITEM_NOT_FOUND, "No linked items")
        payload["has_stored_item"] = True
        payload["identity_status"] = "ready"
        return jsonify(payload), 200
    except UserAuthError as error:
        return jsonify({**payload, "error": str(error)}), 401
    except IdentityStateError as error:
        if error.reason == IdentityStateError.STORED_ITEM_NOT_FOUND:
            payload["identity_status"] = "configured_no_item"
            return jsonify(payload), 200
        if error.reason == IdentityStateError.STORED_ACCESS_TOKEN_MISSING:
            payload["identity_status"] = "configured_item_invalid"
            return jsonify(
                {
                    **payload,
                    "error": "Stored Plaid item is invalid",
                }
            ), 409
        log_route_error("/api/info identity", error)
        return jsonify(
            {
                **payload,
                "identity_status": "error",
                "error": "Failed to load backend identity state",
            }
        ), 500
    except Exception as error:
        log_route_error("/api/info unexpected", error)
        return jsonify(
            {
                **payload,
                "identity_status": "error",
                "error": "Failed to load backend identity state",
            }
        ), 503


@plaid_bp.route("/api/create_link_token", methods=["POST"])
def create_link_token():
    try:
        link_request = LinkTokenCreateRequest(
            products=products,
            client_name="SmartSpend",
            country_codes=[CountryCode(code) for code in PLAID_COUNTRY_CODES],
            language="en",
            user=LinkTokenCreateRequestUser(client_user_id=str(time.time())),
        )
        if PLAID_REDIRECT_URI:
            link_request["redirect_uri"] = PLAID_REDIRECT_URI

        response = client.link_token_create(link_request)
        return jsonify(response.to_dict())
    except plaid.ApiException as error:
        return plaid_error_response(error)


@plaid_bp.route("/api/set_access_token", methods=["POST"])
def set_access_token():
    body = request.get_json(silent=True) or {}
    public_token = body.get("public_token") or request.form.get("public_token")
    if not public_token:
        return jsonify({"error": "Missing public_token"}), 400
    try:
        user_id = require_supabase_user_id()
        exchange_request = ItemPublicTokenExchangeRequest(public_token=public_token)
        exchange_response = client.item_public_token_exchange(exchange_request)
        exchange_data = exchange_response.to_dict()
        access_token = exchange_data["access_token"]
        item_id = exchange_data["item_id"]

        supabase.table("plaid_items").upsert(
            {
                "user_id": user_id,
                "access_token": access_token,
                "item_id": item_id,
            },
            on_conflict="item_id",
        ).execute()

        stored = (
            supabase.table("plaid_items")
            .select("id")
            .eq("item_id", item_id)
            .eq("user_id", user_id)
            .limit(1)
            .execute()
        )
        stored_id = stored.data[0]["id"] if stored.data else item_id

        accounts_synced = save_accounts_to_supabase(user_id, stored_id, access_token)

        return jsonify(
            {
                "item_id": item_id,
                "stored_plaid_item_id": stored_id,
                "accounts_synced": accounts_synced,
                "request_id": exchange_data.get("request_id"),
            }
        )
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except IdentityStateError as error:
        return identity_error_response(error, "/api/set_access_token")
    except plaid.ApiException as error:
        return plaid_error_response(error)


def _first_access_token(user_id: str) -> str:
    items = supabase.table("plaid_items").select("id,access_token").eq("user_id", user_id).limit(1).execute()
    if not items.data or not items.data[0].get("access_token"):
        raise IdentityStateError(IdentityStateError.STORED_ITEM_NOT_FOUND, "No linked items")
    return items.data[0]["access_token"]


@plaid_bp.route("/api/auth", methods=["GET"])
def get_auth():
    try:
        user_id = require_supabase_user_id()
        access_token = _first_access_token(user_id)
        response = client.auth_get(AuthGetRequest(access_token=access_token))
        pretty_print_response(response.to_dict())
        return jsonify(response.to_dict())
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except IdentityStateError as error:
        return identity_error_response(error, "/api/auth")
    except plaid.ApiException as error:
        return plaid_error_response(error)


@plaid_bp.route("/api/transactions", methods=["GET"])
def get_transactions():
    started_at = time.time()
    try:
        user_id = require_supabase_user_id()
        items = supabase.table("plaid_items").select("id,access_token").eq("user_id", user_id).execute()
        if not items.data:
            raise IdentityStateError(IdentityStateError.STORED_ITEM_NOT_FOUND, "No linked items")
        totals = {"added": 0, "modified": 0, "removed": 0}
        for item in items.data:
            access_token = item.get("access_token")
            if not access_token:
                continue
            stats = sync_transactions_to_supabase(user_id, item["id"], access_token)
            for k in totals:
                totals[k] += stats[k]
        current_app.config["snapshot_service"].invalidate(user_id)
        print(f"Sync complete for user {user_id}: {totals}")

        rows = []
        try:
            data = _load_recent_transactions(user_id)
            rows = data.data or []
        except Exception as read_error:
            log_route_error("/api/transactions readback warning", read_error)

        elapsed_ms = int((time.time() - started_at) * 1000)
        return jsonify(
            {
                "latest_transactions": rows,
                "transactions": rows,
                "sync": {**stats, "duration_ms": elapsed_ms},
            }
        )
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except IdentityStateError as error:
        return identity_error_response(error, "/api/transactions")
    except plaid.ApiException as error:
        return plaid_error_response(error)
    except Exception as error:
        log_route_error("/api/transactions unexpected", error)
        return jsonify({"error": "Internal server error"}), 500


@plaid_bp.route("/api/balance", methods=["GET"])
def get_balance():
    try:
        user_id = require_supabase_user_id()
        access_token = _first_access_token(user_id)
        response = client.accounts_balance_get(AccountsBalanceGetRequest(access_token=access_token))
        pretty_print_response(response.to_dict())
        return jsonify(response.to_dict())
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except IdentityStateError as error:
        return identity_error_response(error, "/api/balance")
    except plaid.ApiException as error:
        return plaid_error_response(error)


@plaid_bp.route("/api/accounts", methods=["GET"])
def get_accounts():
    try:
        user_id = require_supabase_user_id()
        access_token = _first_access_token(user_id)
        response = client.accounts_get(AccountsGetRequest(access_token=access_token))
        pretty_print_response(response.to_dict())
        return jsonify(response.to_dict())
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except IdentityStateError as error:
        return identity_error_response(error, "/api/accounts")
    except plaid.ApiException as error:
        return plaid_error_response(error)


@plaid_bp.route("/api/assets", methods=["GET"])
def get_assets():
    try:
        user_id = require_supabase_user_id()
        access_token = _first_access_token(user_id)
        create_request = AssetReportCreateRequest(
            access_tokens=[access_token],
            days_requested=60,
            options=AssetReportCreateRequestOptions(
                webhook="https://www.example.com",
                client_report_id="123",
                user=AssetReportUser(
                    client_user_id="789",
                    first_name="Jane",
                    middle_name="Leah",
                    last_name="Doe",
                    ssn="123-45-6789",
                    phone_number="(555) 123-4567",
                    email="jane.doe@example.com",
                ),
            ),
        )
        response = client.asset_report_create(create_request)
        asset_report_token = response["asset_report_token"]

        report_response = poll_with_retries(
            lambda: client.asset_report_get(
                AssetReportGetRequest(asset_report_token=asset_report_token)
            )
        )
        asset_report_json = report_response["report"]

        pdf = client.asset_report_pdf_get(
            AssetReportPDFGetRequest(asset_report_token=asset_report_token)
        )

        return jsonify(
            {
                "error": None,
                "json": asset_report_json.to_dict(),
                "pdf": base64.b64encode(pdf.read()).decode("utf-8"),
            }
        )
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except IdentityStateError as error:
        return identity_error_response(error, "/api/assets")
    except plaid.ApiException as error:
        return plaid_error_response(error)


@plaid_bp.route("/api/item", methods=["GET"])
def item():
    try:
        user_id = require_supabase_user_id()
        access_token = _first_access_token(user_id)
        response = client.item_get(ItemGetRequest(access_token=access_token))
        institution_response = client.institutions_get_by_id(
            InstitutionsGetByIdRequest(
                institution_id=response["item"]["institution_id"],
                country_codes=[CountryCode(code) for code in PLAID_COUNTRY_CODES],
            )
        )
        pretty_print_response(response.to_dict())
        pretty_print_response(institution_response.to_dict())
        return jsonify(
            {
                "error": None,
                "item": response.to_dict()["item"],
                "institution": institution_response.to_dict()["institution"],
            }
        )
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except IdentityStateError as error:
        return identity_error_response(error, "/api/item")
    except plaid.ApiException as error:
        return plaid_error_response(error)
