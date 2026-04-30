import base64
import time

import plaid
from flask import Flask, jsonify, request
from plaid.model.asset_report_create_request import AssetReportCreateRequest
from plaid.model.asset_report_create_request_options import AssetReportCreateRequestOptions
from plaid.model.asset_report_get_request import AssetReportGetRequest
from plaid.model.asset_report_pdf_get_request import AssetReportPDFGetRequest
from plaid.model.asset_report_user import AssetReportUser
from plaid.model.auth_get_request import AuthGetRequest
from plaid.model.accounts_balance_get_request import AccountsBalanceGetRequest
from plaid.model.accounts_get_request import AccountsGetRequest
from plaid.model.country_code import CountryCode
from plaid.model.institutions_get_by_id_request import InstitutionsGetByIdRequest
from plaid.model.item_get_request import ItemGetRequest
from plaid.model.item_public_token_exchange_request import ItemPublicTokenExchangeRequest
from plaid.model.link_token_create_request import LinkTokenCreateRequest
from plaid.model.link_token_create_request_user import LinkTokenCreateRequestUser

from ai.chat_service import ChatService
from ai.predict_service import PredictService
from ai.providers import generate_llm_reply, ping_llm
from ai.snapshot_service import SpendingSnapshotService
from ai.validators import clamp_str
from auth import is_rate_limited_for_ai, require_api_key
from config import (
    APP_VERSION,
    DEMO_PLAID_ITEM_ID,
    DEMO_USER_ID,
    GIT_SHA,
    HOST,
    OLLAMA_MODEL,
    PLAID_COUNTRY_CODES,
    PLAID_ENV,
    PLAID_PRODUCTS,
    PLAID_REDIRECT_URI,
    PORT,
)
from plaid_sync import (
    client,
    format_error,
    get_stored_item_credentials,
    IdentityStateError,
    poll_with_retries,
    pretty_print_response,
    products,
    require_demo_identity,
    save_accounts_to_supabase,
    sync_transactions_to_supabase,
)
from supabase_repo import supabase

app = Flask(__name__)
app.before_request(require_api_key)

_snapshot_service = SpendingSnapshotService()
_chat_service = ChatService(
    generate_reply=generate_llm_reply,
    get_detailed_snapshot=_snapshot_service.get_cached_snapshot,
)
_predict_service = PredictService(generate_reply=generate_llm_reply)

# ------------------------------------------------------------------ #
#  Routes                                                              #
# ------------------------------------------------------------------ #

RECENT_TRANSACTIONS_LIMIT = 20


def _load_recent_transactions(user_id: str, limit: int = RECENT_TRANSACTIONS_LIMIT):
    """Best-effort recent transaction read for API compatibility callers."""
    return (
        supabase.table("transactions")
        .select("*")
        .eq("user_id", user_id)
        .order("date", desc=True)
        .limit(limit)
        .execute()
    )


def _identity_error_response(error: IdentityStateError, route_name: str):
    reason = getattr(error, "reason", "")
    print(f"{route_name} identity error: {reason}: {type(error).__name__}")
    if reason == IdentityStateError.DEMO_IDENTITY_MISSING:
        return jsonify({
            "error": "Demo identity is not configured",
            "error_code": reason,
        }), 503
    if reason == IdentityStateError.STORED_ITEM_NOT_FOUND:
        return jsonify({
            "error": "No connected Plaid item for demo identity",
            "error_code": reason,
        }), 409
    if reason == IdentityStateError.STORED_ACCESS_TOKEN_MISSING:
        return jsonify({
            "error": "Stored Plaid item is invalid",
            "error_code": reason,
        }), 409
    return jsonify({
        "error": "Failed to resolve backend identity state",
        "error_code": "identity_error",
    }), 500


def _plaid_error_response(error: plaid.ApiException):
    status_code = error.status if isinstance(error.status, int) and 400 <= error.status <= 599 else 502
    return jsonify(format_error(error)), status_code

@app.route('/api/info', methods=['GET'])
def info():
    has_configured_identity = bool(DEMO_USER_ID and DEMO_PLAID_ITEM_ID)
    payload = {
        'products': PLAID_PRODUCTS,
        'plaid_env': PLAID_ENV,
        'has_configured_identity': has_configured_identity,
        'has_stored_item': False,
    }

    if not has_configured_identity:
        payload['identity_status'] = 'not_configured'
        return jsonify(payload), 200

    try:
        get_stored_item_credentials()
        payload['has_stored_item'] = True
        payload['identity_status'] = 'ready'
        return jsonify(payload), 200
    except IdentityStateError as e:
        if e.reason == IdentityStateError.STORED_ITEM_NOT_FOUND:
            payload['identity_status'] = 'configured_no_item'
            return jsonify(payload), 200
        if e.reason == IdentityStateError.STORED_ACCESS_TOKEN_MISSING:
            payload['identity_status'] = 'configured_item_invalid'
            return jsonify({
                **payload,
                'error': 'Stored Plaid item is invalid',
            }), 409
        if e.reason == IdentityStateError.DEMO_IDENTITY_MISSING:
            payload['identity_status'] = 'not_configured'
            return jsonify(payload), 200
        print(f"/api/info identity error: {e.reason}: {type(e).__name__}")
        return jsonify({
            **payload,
            'identity_status': 'error',
            'error': 'Failed to load backend identity state',
        }), 500
    except Exception as e:
        print(f"/api/info unexpected error: {type(e).__name__}: {e}")
        return jsonify({
            **payload,
            'identity_status': 'error',
            'error': 'Failed to load backend identity state',
        }), 503


@app.route('/api/create_link_token', methods=['POST'])
def create_link_token():
    try:
        link_request = LinkTokenCreateRequest(
            products=products,
            client_name="SmartSpend",
            country_codes=list(map(lambda x: CountryCode(x), PLAID_COUNTRY_CODES)),
            language='en',
            user=LinkTokenCreateRequestUser(
                client_user_id=str(time.time())
            )
        )
        if PLAID_REDIRECT_URI:
            link_request['redirect_uri'] = PLAID_REDIRECT_URI

        response = client.link_token_create(link_request)
        return jsonify(response.to_dict())
    except plaid.ApiException as e:
        return _plaid_error_response(e)


@app.route('/api/set_access_token', methods=['POST'])
def set_access_token():
    """
    Exchange a Link public_token for an access_token and save the
    Plaid item + accounts to Supabase.

    Demo user/item row ids are provided via env and used only to scope writes.
    """
    body = request.get_json(silent=True) or {}
    public_token = body.get('public_token') or request.form.get('public_token')
    if not public_token:
        return jsonify({"error": "Missing public_token"}), 400
    try:
        user_id, plaid_item_id = require_demo_identity()
        exchange_request = ItemPublicTokenExchangeRequest(public_token=public_token)
        exchange_response = client.item_public_token_exchange(exchange_request)
        exchange_data = exchange_response.to_dict()
        access_token = exchange_data['access_token']
        item_id = exchange_data['item_id']

        # Persist the item to Supabase
        supabase.table("plaid_items").upsert({
            "id":           plaid_item_id,
            "user_id":      user_id,
            "access_token": access_token,
            "item_id":      item_id,
        }, on_conflict="id").execute()

        # Sync accounts straight away
        accounts_synced = save_accounts_to_supabase(user_id, plaid_item_id, access_token)

        # Do not return Plaid access_token to API callers.
        return jsonify({
            "item_id": item_id,
            "stored_plaid_item_id": plaid_item_id,
            "accounts_synced": accounts_synced,
            "request_id": exchange_data.get("request_id"),
        })
    except IdentityStateError as e:
        return _identity_error_response(e, "/api/set_access_token")
    except plaid.ApiException as e:
        return _plaid_error_response(e)


@app.route('/api/auth', methods=['GET'])
def get_auth():
    try:
        access_token, _ = get_stored_item_credentials()
        response = client.auth_get(AuthGetRequest(access_token=access_token))
        pretty_print_response(response.to_dict())
        return jsonify(response.to_dict())
    except IdentityStateError as e:
        return _identity_error_response(e, "/api/auth")
    except plaid.ApiException as e:
        return _plaid_error_response(e)


@app.route('/api/transactions', methods=['GET'])
def get_transactions():
    started_at = time.time()
    try:
        user_id, plaid_item_id = require_demo_identity()
        access_token, _ = get_stored_item_credentials()
        stats = sync_transactions_to_supabase(user_id, plaid_item_id, access_token)
        _snapshot_service.invalidate(user_id)
        print(f"Sync complete for user {user_id}: {stats}")

        rows = []
        try:
            data = _load_recent_transactions(user_id)
            rows = data.data or []
        except Exception as read_err:
            # Sync is the critical side effect; transaction echo is compatibility output.
            print(f"/api/transactions readback warning: {type(read_err).__name__}: {read_err}")

        elapsed_ms = int((time.time() - started_at) * 1000)

        # Return both formats — quickstart frontend needs 'latest_transactions'
        return jsonify({
            "latest_transactions": rows,
            "transactions": rows,
            "sync": {
                **stats,
                "duration_ms": elapsed_ms,
            },
        })
    except IdentityStateError as e:
        return _identity_error_response(e, "/api/transactions")
    except plaid.ApiException as e:
        return _plaid_error_response(e)
    except Exception as e:
        print(f"/api/transactions unexpected error: {type(e).__name__}: {e}")
        return jsonify({"error": "Internal server error"}), 500

@app.route('/api/balance', methods=['GET'])
def get_balance():
    try:
        access_token, _ = get_stored_item_credentials()
        response = client.accounts_balance_get(
            AccountsBalanceGetRequest(access_token=access_token)
        )
        pretty_print_response(response.to_dict())
        return jsonify(response.to_dict())
    except IdentityStateError as e:
        return _identity_error_response(e, "/api/balance")
    except plaid.ApiException as e:
        return _plaid_error_response(e)


@app.route('/api/accounts', methods=['GET'])
def get_accounts():
    try:
        access_token, _ = get_stored_item_credentials()
        response = client.accounts_get(AccountsGetRequest(access_token=access_token))
        pretty_print_response(response.to_dict())
        return jsonify(response.to_dict())
    except IdentityStateError as e:
        return _identity_error_response(e, "/api/accounts")
    except plaid.ApiException as e:
        return _plaid_error_response(e)


@app.route('/api/assets', methods=['GET'])
def get_assets():
    try:
        access_token, _ = get_stored_item_credentials()
        create_req = AssetReportCreateRequest(
            access_tokens=[access_token],
            days_requested=60,
            options=AssetReportCreateRequestOptions(
                webhook='https://www.example.com',
                client_report_id='123',
                user=AssetReportUser(
                    client_user_id='789',
                    first_name='Jane',
                    middle_name='Leah',
                    last_name='Doe',
                    ssn='123-45-6789',
                    phone_number='(555) 123-4567',
                    email='jane.doe@example.com',
                )
            )
        )
        response = client.asset_report_create(create_req)
        asset_report_token = response['asset_report_token']

        get_req = AssetReportGetRequest(asset_report_token=asset_report_token)
        response = poll_with_retries(lambda: client.asset_report_get(get_req))
        asset_report_json = response['report']

        pdf_req = AssetReportPDFGetRequest(asset_report_token=asset_report_token)
        pdf = client.asset_report_pdf_get(pdf_req)

        return jsonify({
            'error': None,
            'json':  asset_report_json.to_dict(),
            'pdf':   base64.b64encode(pdf.read()).decode('utf-8'),
        })
    except IdentityStateError as e:
        return _identity_error_response(e, "/api/assets")
    except plaid.ApiException as e:
        return _plaid_error_response(e)


@app.route('/api/item', methods=['GET'])
def item():
    try:
        access_token, _ = get_stored_item_credentials()
        response = client.item_get(ItemGetRequest(access_token=access_token))
        inst_response = client.institutions_get_by_id(
            InstitutionsGetByIdRequest(
                institution_id=response['item']['institution_id'],
                country_codes=list(map(lambda x: CountryCode(x), PLAID_COUNTRY_CODES))
            )
        )
        pretty_print_response(response.to_dict())
        pretty_print_response(inst_response.to_dict())
        return jsonify({
            'error':       None,
            'item':        response.to_dict()['item'],
            'institution': inst_response.to_dict()['institution'],
        })
    except IdentityStateError as e:
        return _identity_error_response(e, "/api/item")
    except plaid.ApiException as e:
        return _plaid_error_response(e)


@app.route('/api/ai/chat', methods=['POST'])
def ai_chat():
    if is_rate_limited_for_ai():
        return jsonify({"error": "Rate limit exceeded"}), 429
    body = request.get_json(silent=True) or {}
    try:
        user_id, _ = require_demo_identity()
        response = _chat_service.handle_chat(body, user_id=user_id)
        return jsonify(response)
    except IdentityStateError as e:
        return _identity_error_response(e, "/api/ai/chat")
    except ValueError as e:
        return jsonify({"error": str(e)}), 400
    except Exception as e:
        print(f"/api/ai/chat error: {type(e).__name__}: {e}")
        return jsonify(
            {
                "reply": "I cannot process this request right now. Please try again.",
                "insights": ["The assistant returned a safe fallback response due to a backend error."],
                "actions": ["Try again in a moment."],
                "confidence": 0.0,
                "citations": ["rule_fallback"],
                "intent": "general",
                "context_source": "rule_fallback",
                "used_summary": False,
                "summary_meta": {"tx_count_30d": 0, "summary_empty": True},
            }
        ), 200


@app.route('/api/ai/budget_suggest', methods=['POST'])
def ai_budget_suggest():
    # Compatibility adapter for existing Flutter callers.
    if is_rate_limited_for_ai():
        return jsonify({"error": "Rate limit exceeded"}), 429
    body = request.get_json(silent=True) or {}
    predict_payload = {
        "type": "budget_overrun_forecast",
        "view_mode": clamp_str(body.get("view_mode", "month"), 16) or "month",
        "spending_summary": body.get("spending_summary"),
        "budget_progress": body.get("budget_progress"),
        "simplified": bool(body.get("simplified", False)),
    }
    simplified = bool(predict_payload["simplified"])

    def _confidence_label(score):
        value = float(score or 0.0)
        if value >= 0.75:
            return "high"
        if value >= 0.45:
            return "medium"
        return "low"

    def _short_copy(text):
        value = clamp_str(text, 220)
        if not value:
            return ""
        for sep in (". ", "! ", "? "):
            idx = value.find(sep)
            if idx > 0:
                return clamp_str(value[: idx + 1], 160)
        return clamp_str(value, 160)
    try:
        response = _predict_service.handle_predict(predict_payload)
        confidence_score = float(response.get("confidence", 0.0) or 0.0)
        confidence = _confidence_label(confidence_score)
        copy = response.get("copy", "")
        alerts = response.get("alerts", [])
        actions = response.get("next_actions", [])

        if simplified:
            copy = _short_copy(copy)
            if not copy:
                copy = "Budget risk detected. Focus on the highest-pressure categories this week."
            alerts = (alerts or [])[:2]
            actions = (actions or [])[:2]

        suggestions = {
            "copy": copy,
            "alerts": alerts,
            "actions": actions,
            "confidence": confidence,
            "confidence_score": round(confidence_score, 2),
        }
        if simplified:
            context_source = "deterministic_simplified"
        else:
            context_source = "rule_fallback" if response.get("fallback_used") else "frontend_summary"
        return jsonify({"suggestions": suggestions, "context_source": context_source})
    except ValueError as e:
        return jsonify({"error": str(e)}), 400
    except Exception as e:
        print(f"/api/ai/budget_suggest error: {type(e).__name__}: {e}")
        return jsonify(
            {
                "suggestions": {
                    "copy": "Unable to generate prediction now.",
                    "alerts": [],
                    "actions": [{"id": "retry", "label": "Retry in a moment"}],
                    "confidence": 0.0,
                },
                "context_source": "rule_fallback",
            }
        ), 200


@app.route('/api/ai/predict', methods=['POST'])
def ai_predict():
    if is_rate_limited_for_ai():
        return jsonify({"error": "Rate limit exceeded"}), 429
    body = request.get_json(silent=True) or {}
    try:
        response = _predict_service.handle_predict(body)
        return jsonify(response)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400
    except Exception as e:
        print(f"/api/ai/predict error: {type(e).__name__}: {e}")
        return jsonify(
            {
                "type": clamp_str((body or {}).get("type", "unknown"), 48) or "unknown",
                "forecast": {},
                "copy": "Unable to generate prediction now.",
                "why": ["Unexpected internal failure."],
                "alerts": [],
                "next_actions": [{"id": "retry", "label": "Retry in a moment"}],
                "confidence": 0.0,
                "fallback_used": True,
            }
        ), 200


@app.route('/api/ai/ping', methods=['GET'])
def ai_ping():
    try:
        return jsonify(ping_llm())
    except Exception as e:
        return jsonify({
            "ok": False,
            "model": OLLAMA_MODEL,
            "error_type": "server_error",
            "detail": str(e),
        }), 500


@app.route('/api/health', methods=['GET'])
def health():
    return jsonify({
        "ok": True,
        "version": APP_VERSION,
        "git_sha": GIT_SHA,
        "model": OLLAMA_MODEL,
    })


if __name__ == '__main__':
    app.run(
        host=HOST,
        port=PORT,
    )
