"""AI-related API routes."""

from flask import Blueprint, current_app, jsonify, request

from ai.response_utils import confidence_label, short_copy
from ai.validators import clamp_str
from api.http_helpers import log_route_error
from auth import UserAuthError, is_rate_limited_for_ai, require_supabase_user_id

ai_bp = Blueprint("ai", __name__)


@ai_bp.route("/api/ai/chat", methods=["POST"])
def ai_chat():
    if is_rate_limited_for_ai():
        return jsonify({"error": "Rate limit exceeded"}), 429
    body = request.get_json(silent=True) or {}
    try:
        user_id = require_supabase_user_id()
        response = current_app.config["chat_service"].handle_chat(body, user_id=user_id)
        return jsonify(response)
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except ValueError as error:
        return jsonify({"error": str(error)}), 400
    except Exception as error:
        log_route_error("/api/ai/chat", error)
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
    if is_rate_limited_for_ai():
        return jsonify({"error": "Rate limit exceeded"}), 429
    body = request.get_json(silent=True) or {}
    try:
        response = current_app.config["predict_service"].handle_predict(body)
        return jsonify(response)
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
