import time

from flask import Flask, jsonify, request

from ai.chat_service import ChatService
from ai.predict_service import PredictService
from ai.providers import generate_llm_reply, ping_llm
from ai.snapshot_service import SpendingSnapshotService
from ai.validators import clamp_str
from auth import (
    is_rate_limited_for_ai,
    require_api_key,
    require_supabase_user_id,
    UserAuthError,
)
from config import (
    APP_VERSION,
    DEMO_BANK_CONNECTION_ID,
    DEMO_USER_ID,
    GIT_SHA,
    HOST,
    OLLAMA_MODEL,
    PORT,
    TELLER_ENV,
    TELLER_PRODUCTS,
)
from teller_sync import (
    format_error,
    get_stored_connection_credentials,
    IdentityStateError,
    require_demo_identity,
    store_teller_access_token,
    sync_accounts_to_supabase,
    sync_transactions_to_supabase,
    TellerApiError,
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
        supabase.table("teller_transactions")
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
    if reason == IdentityStateError.STORED_CONNECTION_NOT_FOUND:
        return jsonify({
            "error": "No connected bank connection for demo identity",
            "error_code": reason,
        }), 409
    if reason == IdentityStateError.STORED_ACCESS_TOKEN_MISSING:
        return jsonify({
            "error": "Stored bank connection is invalid",
            "error_code": reason,
        }), 409
    return jsonify({
        "error": "Failed to resolve backend identity state",
        "error_code": "identity_error",
    }), 500


def _provider_error_response(error: TellerApiError):
    status_code = (
        error.status_code
        if isinstance(error.status_code, int) and 400 <= error.status_code <= 599
        else 502
    )
    return jsonify(format_error(error)), status_code


def _request_user_id() -> str:
    return require_supabase_user_id()

@app.route('/api/info', methods=['GET'])
def info():
    has_configured_identity = bool(DEMO_USER_ID)
    payload = {
        'products': TELLER_PRODUCTS,
        'teller_env': TELLER_ENV,
        'has_configured_identity': has_configured_identity,
        'has_stored_connection': False,
    }

    if not has_configured_identity:
        payload['identity_status'] = 'not_configured'
        return jsonify(payload), 200

    try:
        get_stored_connection_credentials()
        payload['has_stored_connection'] = True
        payload['identity_status'] = 'ready'
        return jsonify(payload), 200
    except IdentityStateError as e:
        if e.reason == IdentityStateError.STORED_CONNECTION_NOT_FOUND:
            payload['identity_status'] = 'configured_no_connection'
            return jsonify(payload), 200
        if e.reason == IdentityStateError.STORED_ACCESS_TOKEN_MISSING:
            payload['identity_status'] = 'configured_connection_invalid'
            return jsonify({
                **payload,
                'error': 'Stored bank connection is invalid',
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


@app.route('/api/teller/access_token', methods=['POST'])
def set_teller_access_token():
    """Persist a Teller Connect access token and sync accounts immediately."""
    body = request.get_json(silent=True) or {}
    access_token = body.get('access_token') or body.get('accessToken')
    if not access_token:
        return jsonify({"error": "Missing access_token"}), 400
    try:
        user_id = _request_user_id()
        configured_connection_id = DEMO_BANK_CONNECTION_ID
        connection_id = (
            body.get('connection_id')
            or body.get('connectionId')
            or configured_connection_id
        )
        enrollment = body.get('enrollment') or {}
        if not isinstance(enrollment, dict):
            enrollment = {}
        institution = body.get('institution') or enrollment.get('institution') or {}
        if not isinstance(institution, dict):
            institution = {"name": str(institution)}
        enrollment_id = (
            body.get('enrollment_id')
            or body.get('enrollmentId')
            or enrollment.get('id')
        )
        store_teller_access_token(
            user_id=user_id,
            connection_id=connection_id,
            access_token=access_token,
            enrollment_id=enrollment_id,
            institution=institution,
        )
        accounts = sync_accounts_to_supabase(user_id, connection_id, access_token)
        return jsonify({
            "stored_connection_id": connection_id,
            "accounts_synced": len(accounts),
            "provider": "teller",
        })
    except IdentityStateError as e:
        return _identity_error_response(e, "/api/teller/access_token")
    except UserAuthError as e:
        return jsonify({"error": str(e)}), 401
    except TellerApiError as e:
        return _provider_error_response(e)


@app.route('/api/transactions', methods=['GET'])
def get_transactions():
    started_at = time.time()
    try:
        user_id = _request_user_id()
        access_token, connection = get_stored_connection_credentials(
            user_id=user_id,
            connection_id=DEMO_BANK_CONNECTION_ID,
        )
        connection_id = connection["id"]
        stats = sync_transactions_to_supabase(
            user_id,
            connection_id,
            access_token,
            connection,
        )
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

        # Keep both keys for API compatibility with existing clients.
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
    except UserAuthError as e:
        return jsonify({"error": str(e)}), 401
    except TellerApiError as e:
        return _provider_error_response(e)
    except Exception as e:
        print(f"/api/transactions unexpected error: {type(e).__name__}: {e}")
        return jsonify({"error": "Internal server error"}), 500


@app.route('/api/accounts', methods=['GET'])
def get_accounts():
    try:
        user_id = _request_user_id()
        access_token, connection = get_stored_connection_credentials(
            user_id=user_id,
            connection_id=DEMO_BANK_CONNECTION_ID,
        )
        connection_id = connection["id"]
        sync_accounts_to_supabase(user_id, connection_id, access_token)
        rows = (
            supabase.table("teller_accounts")
            .select("*")
            .eq("user_id", user_id)
            .order("name")
            .execute()
        )
        return jsonify({"accounts": rows.data or []})
    except IdentityStateError as e:
        return _identity_error_response(e, "/api/accounts")
    except UserAuthError as e:
        return jsonify({"error": str(e)}), 401
    except TellerApiError as e:
        return _provider_error_response(e)


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
