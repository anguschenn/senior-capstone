"""System and health routes."""

from flask import Blueprint, jsonify

from ai.providers import current_llm_info, ping_llm
from api.http_helpers import log_route_error
from auth import UserAuthError, is_rate_limited_for_ai, require_supabase_user_id
from config import APP_VERSION, GIT_SHA

system_bp = Blueprint("system", __name__)


@system_bp.route("/api/ai/ping", methods=["GET"])
def ai_ping():
    """Round-trip the LLM. Costs a model call, so it needs a signed-in user and is
    rate-limited with the other AI endpoints."""
    llm_info = current_llm_info()
    try:
        user_id = require_supabase_user_id()
        if is_rate_limited_for_ai(user_id):
            return jsonify({"error": "Rate limit exceeded"}), 429
        return jsonify(ping_llm())
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except Exception as error:
        # Provider errors can carry hosts, URLs or upstream bodies: log, never return.
        log_route_error("/api/ai/ping", error)
        return jsonify(
            {
                "ok": False,
                "model": llm_info["model"],
                "provider": llm_info["provider"],
                "error_type": "server_error",
            }
        ), 500


@system_bp.route("/api/health", methods=["GET"])
def health():
    llm_info = current_llm_info()
    return jsonify(
        {
            "ok": True,
            "version": APP_VERSION,
            "git_sha": GIT_SHA,
            "model": llm_info["model"],
            "provider": llm_info["provider"],
        }
    )


@system_bp.route("/healthz", methods=["GET"])
def healthz():
    """Unauthenticated liveness probe for the host's health checks.

    Deliberately outside the /api/ prefix so it bypasses require_api_key();
    Render cannot attach custom headers to health checks, so a gated endpoint
    would read as permanently unhealthy. Returns no data about the service.
    """
    return jsonify({"status": "ok"}), 200
