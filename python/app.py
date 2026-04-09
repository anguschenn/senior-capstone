"""Flask application factory: route registration, health check, startup."""

import base64
import json
import os
import subprocess
import time
import urllib.error

import plaid
from flask import Flask, request, jsonify
from plaid.model.country_code import CountryCode

from config import (
    PORT,
    ENV,
    PLAID_PRODUCTS,
    PLAID_ENV,
    PLAID_COUNTRY_CODES,
    PLAID_REDIRECT_URI,
    GEMINI_MODEL,
    DEMO_USER_ID,
    DEMO_PLAID_ITEM_ID,
    AI_MAX_REQUEST_BYTES,
)
from auth import require_api_key, is_rate_limited_for_ai
from ai import (
    _generate_gemini_reply,
    get_cached_spending_snapshot,
    invalidate_spending_snapshot_cache,
    sanitize_client_spending_summary,
    format_client_summary_for_prompt,
    build_enhanced_prompt,
    build_budget_suggest_prompt,
    sanitize_budget_progress,
)
from plaid_sync import (
    client,
    products,
    require_demo_identity,
    get_stored_item_credentials,
    save_accounts_to_supabase,
    sync_transactions_to_supabase,
    poll_with_retries,
    format_error,
    pretty_print_response,
)
from supabase_repo import supabase
from plaid.model.link_token_create_request import LinkTokenCreateRequest
from plaid.model.link_token_create_request_user import LinkTokenCreateRequestUser
from plaid.model.asset_report_create_request import AssetReportCreateRequest
from plaid.model.asset_report_create_request_options import AssetReportCreateRequestOptions
from plaid.model.asset_report_user import AssetReportUser
from plaid.model.asset_report_get_request import AssetReportGetRequest
from plaid.model.asset_report_pdf_get_request import AssetReportPDFGetRequest
from plaid.model.auth_get_request import AuthGetRequest
from plaid.model.accounts_balance_get_request import AccountsBalanceGetRequest
from plaid.model.accounts_get_request import AccountsGetRequest
from plaid.model.item_get_request import ItemGetRequest
from plaid.model.institutions_get_by_id_request import InstitutionsGetByIdRequest

# ── App init ─────────────────────────────────────────────────────────

app = Flask(__name__)
_START_TIME = time.time()


def _git_sha() -> str:
    try:
        return (
            subprocess.check_output(
                ["git", "rev-parse", "--short", "HEAD"],
                stderr=subprocess.DEVNULL,
            )
            .decode()
            .strip()
        )
    except Exception:
        return "unknown"


_GIT_SHA = _git_sha()

app.before_request(require_api_key)


# ── Health ───────────────────────────────────────────────────────────


@app.route("/api/health", methods=["GET"])
def health():
    return jsonify(
        {
            "status": "ok",
            "git_sha": _GIT_SHA,
            "model": GEMINI_MODEL,
            "env": ENV,
            "uptime_s": round(time.time() - _START_TIME),
        }
    )


# ── Info ─────────────────────────────────────────────────────────────


@app.route("/api/info", methods=["POST"])
def info():
    has_configured_identity = bool(DEMO_USER_ID and DEMO_PLAID_ITEM_ID)
    has_stored_item = False
    if has_configured_identity:
        try:
            get_stored_item_credentials()
            has_stored_item = True
        except Exception:
            pass
    return jsonify(
        {
            "products": PLAID_PRODUCTS,
            "plaid_env": PLAID_ENV,
            "has_configured_identity": has_configured_identity,
            "has_stored_item": has_stored_item,
        }
    )


# ── Plaid link ───────────────────────────────────────────────────────


@app.route("/api/create_link_token", methods=["POST"])
def create_link_token():
    try:
        link_request = LinkTokenCreateRequest(
            products=products,
            client_name="SmartSpend",
            country_codes=[CountryCode(x) for x in PLAID_COUNTRY_CODES],
            language="en",
            user=LinkTokenCreateRequestUser(client_user_id=str(time.time())),
        )
        if PLAID_REDIRECT_URI:
            link_request["redirect_uri"] = PLAID_REDIRECT_URI
        response = client.link_token_create(link_request)
        return jsonify(response.to_dict())
    except plaid.ApiException as e:
        return json.loads(e.body)


@app.route("/api/set_access_token", methods=["POST"])
def set_access_token():
    user_id, plaid_item_id = require_demo_identity()
    body = request.get_json(silent=True) or {}
    public_token = body.get("public_token") or request.form.get("public_token")
    if not public_token:
        return jsonify({"error": "Missing public_token"}), 400
    try:
        from plaid.model.item_public_token_exchange_request import (
            ItemPublicTokenExchangeRequest,
        )

        exchange_response = client.item_public_token_exchange(
            ItemPublicTokenExchangeRequest(public_token=public_token)
        )
        access_token = exchange_response["access_token"]
        item_id = exchange_response["item_id"]

        supabase.table("plaid_items").upsert(
            {
                "id": plaid_item_id,
                "user_id": user_id,
                "access_token": access_token,
                "item_id": item_id,
            },
            on_conflict="id",
        ).execute()

        save_accounts_to_supabase(user_id, plaid_item_id, access_token)
        return jsonify(exchange_response.to_dict())
    except plaid.ApiException as e:
        return json.loads(e.body)


# ── Plaid data ───────────────────────────────────────────────────────


@app.route("/api/auth", methods=["GET"])
def get_auth():
    try:
        access_token, _ = get_stored_item_credentials()
        response = client.auth_get(AuthGetRequest(access_token=access_token))
        pretty_print_response(response.to_dict())
        return jsonify(response.to_dict())
    except plaid.ApiException as e:
        return jsonify(format_error(e))


@app.route("/api/transactions", methods=["GET"])
def get_transactions():
    try:
        user_id, plaid_item_id = require_demo_identity()
        access_token, _ = get_stored_item_credentials()
        stats = sync_transactions_to_supabase(user_id, plaid_item_id, access_token)
        invalidate_spending_snapshot_cache(user_id)
        print(f"Sync complete: {stats}")

        data = (
            supabase.table("transactions")
            .select("*")
            .eq("user_id", user_id)
            .order("date", desc=True)
            .limit(20)
            .execute()
        )
        return jsonify(
            {
                "latest_transactions": data.data,
                "transactions": data.data,
                "sync": stats,
            }
        )
    except plaid.ApiException as e:
        return jsonify(format_error(e))
    except Exception as e:
        print(f"/api/transactions error: {e}")
        return jsonify({"error": "Internal server error"}), 500


@app.route("/api/balance", methods=["GET"])
def get_balance():
    try:
        access_token, _ = get_stored_item_credentials()
        response = client.accounts_balance_get(
            AccountsBalanceGetRequest(access_token=access_token)
        )
        pretty_print_response(response.to_dict())
        return jsonify(response.to_dict())
    except plaid.ApiException as e:
        return jsonify(format_error(e))


@app.route("/api/accounts", methods=["GET"])
def get_accounts():
    try:
        access_token, _ = get_stored_item_credentials()
        response = client.accounts_get(AccountsGetRequest(access_token=access_token))
        pretty_print_response(response.to_dict())
        return jsonify(response.to_dict())
    except plaid.ApiException as e:
        return jsonify(format_error(e))


@app.route("/api/assets", methods=["GET"])
def get_assets():
    try:
        access_token, _ = get_stored_item_credentials()
        create_req = AssetReportCreateRequest(
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
        response = client.asset_report_create(create_req)
        asset_report_token = response["asset_report_token"]

        get_req = AssetReportGetRequest(asset_report_token=asset_report_token)
        response = poll_with_retries(lambda: client.asset_report_get(get_req))
        asset_report_json = response["report"]

        pdf_req = AssetReportPDFGetRequest(asset_report_token=asset_report_token)
        pdf = client.asset_report_pdf_get(pdf_req)

        return jsonify(
            {
                "error": None,
                "json": asset_report_json.to_dict(),
                "pdf": base64.b64encode(pdf.read()).decode("utf-8"),
            }
        )
    except plaid.ApiException as e:
        return jsonify(format_error(e))


@app.route("/api/item", methods=["GET"])
def item():
    try:
        access_token, _ = get_stored_item_credentials()
        response = client.item_get(ItemGetRequest(access_token=access_token))
        inst_response = client.institutions_get_by_id(
            InstitutionsGetByIdRequest(
                institution_id=response["item"]["institution_id"],
                country_codes=[CountryCode(x) for x in PLAID_COUNTRY_CODES],
            )
        )
        pretty_print_response(response.to_dict())
        pretty_print_response(inst_response.to_dict())
        return jsonify(
            {
                "error": None,
                "item": response.to_dict()["item"],
                "institution": inst_response.to_dict()["institution"],
            }
        )
    except plaid.ApiException as e:
        return jsonify(format_error(e))


# ── AI chat ──────────────────────────────────────────────────────────


@app.route("/api/ai/chat", methods=["POST"])
def ai_chat():
    if request.content_length and request.content_length > AI_MAX_REQUEST_BYTES:
        return jsonify({"error": "Request body too large"}), 413

    if is_rate_limited_for_ai():
        return jsonify({"error": "Rate limit exceeded. Try again shortly."}), 429

    body = request.get_json(silent=True) or {}
    prompt = (body.get("prompt") or "").strip()
    if not prompt:
        return jsonify({"error": "Missing prompt"}), 400
    if len(prompt) > 4000:
        return jsonify({"error": "Prompt too long"}), 400

    try:
        user_id, _ = require_demo_identity()

        client_summary = sanitize_client_spending_summary(body.get("spending_summary"))
        if client_summary is not None:
            spending_snapshot = format_client_summary_for_prompt(client_summary)
            context_source = "frontend_summary"
        else:
            spending_snapshot = get_cached_spending_snapshot(user_id)
            context_source = "server_snapshot"

        enhanced_prompt = build_enhanced_prompt(spending_snapshot, context_source, prompt)
        reply = _generate_gemini_reply(enhanced_prompt)
        return jsonify({"reply": reply, "context_source": context_source})

    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8")
        except Exception:
            detail = "<unreadable>"
        print(f"Gemini HTTP error {e.code}: {detail[:200]}")
        return jsonify({"error": "Gemini request failed"}), 502
    except Exception as e:
        print(f"/api/ai/chat error: {type(e).__name__}: {e}")
        return jsonify({"error": "Internal server error"}), 500


@app.route("/api/ai/budget_suggest", methods=["POST"])
def ai_budget_suggest():
    if request.content_length and request.content_length > AI_MAX_REQUEST_BYTES:
        return jsonify({"error": "Request body too large"}), 413

    if is_rate_limited_for_ai():
        return jsonify({"error": "Rate limit exceeded. Try again shortly."}), 429

    body = request.get_json(silent=True) or {}
    view_mode = (body.get("view_mode") or "month").strip()[:16]

    try:
        user_id, _ = require_demo_identity()

        client_summary = sanitize_client_spending_summary(body.get("spending_summary"))
        if client_summary is not None:
            spending_snapshot = format_client_summary_for_prompt(client_summary)
            context_source = "frontend_summary"
        else:
            spending_snapshot = get_cached_spending_snapshot(user_id)
            context_source = "server_snapshot"

        budget_progress = sanitize_budget_progress(body.get("budget_progress"))
        prompt = build_budget_suggest_prompt(
            spending_snapshot, context_source, budget_progress, view_mode
        )
        raw_reply = _generate_gemini_reply(prompt)

        import json as _json
        try:
            suggestions = _json.loads(raw_reply)
        except _json.JSONDecodeError:
            suggestions = {"copy": raw_reply[:500], "alerts": [], "actions": []}

        return jsonify({"suggestions": suggestions, "context_source": context_source})

    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8")
        except Exception:
            detail = "<unreadable>"
        print(f"Gemini HTTP error {e.code}: {detail[:200]}")
        return jsonify({"error": "Gemini request failed"}), 502
    except Exception as e:
        print(f"/api/ai/budget_suggest error: {type(e).__name__}: {e}")
        return jsonify({"error": "Internal server error"}), 500


@app.route("/api/ai/ping", methods=["GET"])
def ai_ping():
    try:
        reply = _generate_gemini_reply("Reply with exactly: pong")
        return jsonify(
            {"ok": True, "model": GEMINI_MODEL, "reply_preview": reply[:80]}
        )
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8")
        except Exception:
            detail = "<unreadable>"
        return (
            jsonify(
                {
                    "ok": False,
                    "model": GEMINI_MODEL,
                    "error_type": "gemini_http_error",
                    "status_code": e.code,
                    "detail": detail[:300],
                }
            ),
            502,
        )
    except Exception as e:
        return (
            jsonify(
                {
                    "ok": False,
                    "model": GEMINI_MODEL,
                    "error_type": "server_error",
                    "detail": str(e),
                }
            ),
            500,
        )


# ── Entry point ──────────────────────────────────────────────────────

if __name__ == "__main__":
    if ENV == "production":
        print(
            "WARNING: Use gunicorn in production: "
            "gunicorn -w 2 -b 0.0.0.0:$PORT app:app"
        )
    app.run(port=PORT, debug=(ENV == "development"))
