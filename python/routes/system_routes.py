"""System and health routes."""

from flask import Blueprint, jsonify

from ai.providers import current_llm_info, ping_llm
from config import APP_VERSION, GIT_SHA

system_bp = Blueprint("system", __name__)


@system_bp.route("/api/ai/ping", methods=["GET"])
def ai_ping():
    llm_info = current_llm_info()
    try:
        return jsonify(ping_llm())
    except Exception as error:
        return jsonify(
            {
                "ok": False,
                "model": llm_info["model"],
                "provider": llm_info["provider"],
                "error_type": "server_error",
                "detail": str(error),
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
