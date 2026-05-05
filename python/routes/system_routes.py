"""System and health routes."""

from flask import Blueprint, jsonify

from ai.providers import ping_llm
from config import APP_VERSION, GIT_SHA, OLLAMA_MODEL

system_bp = Blueprint("system", __name__)


@system_bp.route("/api/ai/ping", methods=["GET"])
def ai_ping():
    try:
        return jsonify(ping_llm())
    except Exception as error:
        return jsonify({
            "ok": False,
            "model": OLLAMA_MODEL,
            "error_type": "server_error",
            "detail": str(error),
        }), 500


@system_bp.route("/api/health", methods=["GET"])
def health():
    return jsonify({
        "ok": True,
        "version": APP_VERSION,
        "git_sha": GIT_SHA,
        "model": OLLAMA_MODEL,
    })
