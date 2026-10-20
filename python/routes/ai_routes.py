"""AI-related API routes."""

from flask import Blueprint, current_app, jsonify, request

from ai import server_summary
from ai.response_utils import confidence_label, short_copy
from ai.validators import clamp_str
from api.http_helpers import log_route_error
from auth import UserAuthError, is_rate_limited_for_ai, require_supabase_user_id
from config import CHAT_SERVER_SUMMARY_ENABLED

ai_bp = Blueprint("ai", __name__)


def _record_question(body, response):
    """Keep the masked wording of the question and whether chat answered it."""
    record = current_app.config.get("question_log")
    if record and isinstance(body, dict):
        record(body.get("prompt") or body.get("message") or "", response)


def _with_server_summary(body, user_id):
    """(body, source). With a `context` block, spending_summary is replaced by one built
    from Supabase (source "server"); if that fails, the app's own summary is used ("app"),
    and with neither the app is asked to resend with its summary (body None)."""
    context = server_summary.parse_context(body.get("context"))
    if context is None:
        return body, "app"
    if CHAT_SERVER_SUMMARY_ENABLED:
        try:
            summary = server_summary.summary_for(user_id, context)
            return {**body, "spending_summary": summary}, "server"
        except Exception as error:
            log_route_error("/api/ai/chat server summary", error)
    if isinstance(body.get("spending_summary"), dict):
        return body, "app"
    return None, "app"


@ai_bp.route("/api/ai/chat", methods=["POST"])
def ai_chat():
    body = request.get_json(silent=True) or {}
    try:
        user_id = require_supabase_user_id()
        if is_rate_limited_for_ai(user_id):
            return jsonify({"error": "Rate limit exceeded"}), 429
        payload, summary_source = _with_server_summary(body, user_id)
        if payload is None:
            return jsonify({"retry_with_summary": True}), 200
        response = current_app.config["chat_service"].handle_chat(payload, user_id=user_id)
        if isinstance(response, dict):
            response["summary_source"] = summary_source
        _record_question(body, response)
        return jsonify(response)
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except ValueError as error:
        return jsonify({"error": str(error)}), 400
    except Exception as error:
        log_route_error("/api/ai/chat", error)
        _record_question(body, {"context_source": "rule_fallback"})
        return jsonify(
            {
                "reply": "I cannot process this request right now. Please try again.",
                "insights": [
                    "The assistant returned a safe fallback response due to a backend error."
                ],
                "actions": ["Try again in a moment."],
                "confidence": 0.0,
                "citations": ["rule_fallback"],
                "intent": "general",
                "context_source": "rule_fallback",
                "used_summary": False,
                "summary_meta": {"tx_count_30d": 0, "summary_empty": True},
            }
        ), 200


@ai_bp.route("/api/ai/budget_suggest", methods=["POST"])
def ai_budget_suggest():
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
    try:
        response = current_app.config["predict_service"].handle_predict(predict_payload)
        confidence_score = float(response.get("confidence", 0.0) or 0.0)
        confidence = confidence_label(confidence_score)
        copy = response.get("copy", "")
        alerts = response.get("alerts", [])
        actions = response.get("next_actions", [])

        if simplified:
            copy = short_copy(copy)
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
            context_source = (
                "rule_fallback" if response.get("fallback_used") else "frontend_summary"
            )
        return jsonify({"suggestions": suggestions, "context_source": context_source})
    except ValueError as error:
        return jsonify({"error": str(error)}), 400
    except Exception as error:
        log_route_error("/api/ai/budget_suggest", error)
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


@ai_bp.route("/api/ai/predict", methods=["POST"])
def ai_predict():
    body = request.get_json(silent=True) or {}
    try:
        user_id = require_supabase_user_id()
        if is_rate_limited_for_ai(user_id):
            return jsonify({"error": "Rate limit exceeded"}), 429
        response = current_app.config["predict_service"].handle_predict(body)
        return jsonify(response)
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except ValueError as error:
        return jsonify({"error": str(error)}), 400
    except Exception as error:
        log_route_error("/api/ai/predict", error)
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


@ai_bp.route("/api/ai/suggest_category", methods=["POST"])
def ai_suggest_category():
    body = request.get_json(silent=True) or {}
    try:
        # Raises UserAuthError -> 401 for unauthenticated callers. The id only keys the
        # rate limit; the suggestion is derived only from the posted transaction.
        user_id = require_supabase_user_id()
        if is_rate_limited_for_ai(user_id):
            return jsonify({"error": "Rate limit exceeded"}), 429
        merchant_name = clamp_str(body.get("merchant_name", ""), 256) or ""
        transaction_name = clamp_str(body.get("transaction_name", ""), 256) or ""
        pfc_primary = clamp_str(body.get("pfc_primary", ""), 128) or ""
        pfc_detailed = clamp_str(body.get("pfc_detailed", ""), 128) or ""

        if not merchant_name and not transaction_name:
            return jsonify({"error": "merchant_name or transaction_name required"}), 400

        # Build prompt for category suggestion
        context = f"Merchant: {merchant_name}\nDescription: {transaction_name}"
        if pfc_primary:
            context += f"\nPFC Primary: {pfc_primary}"
        if pfc_detailed:
            context += f"\nPFC Detailed: {pfc_detailed}"

        prompt = (
            f"Based on this transaction, suggest a single best category name (2-3 words). "
            f"Return ONLY the category name, nothing else.\n\n{context}"
        )

        # Get suggestion from LLM
        # generate_reply is providers.generate_llm_reply(prompt, generation_config=None).
        reply = current_app.config["chat_service"].generate_reply(prompt)

        suggested_category = reply.strip() if reply else ""

        return jsonify(
            {
                "suggested_category": suggested_category,
                "merchant_name": merchant_name,
                "transaction_name": transaction_name,
                "context_source": "ai_suggestion",
            }
        )
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except ValueError as error:
        return jsonify({"error": str(error)}), 400
    except Exception as error:
        log_route_error("/api/ai/suggest_category", error)
        return jsonify(
            {
                "error": "Unable to suggest category at this time.",
                "context_source": "rule_fallback",
            }
        ), 200
