"""Flask app factory and route registration."""

import logging

from flask import Flask
from flask_cors import CORS

from ai.chat_service import ChatService
from ai.predict_service import PredictService
from ai.providers import generate_llm_reply
from ai.snapshot_service import SpendingSnapshotService
from auth import require_api_key
from config import ALLOWED_ORIGINS
from routes.ai_routes import ai_bp
from routes.plaid_routes import plaid_bp
from routes.system_routes import system_bp


def create_app() -> Flask:
    app = Flask(__name__)
    if not ALLOWED_ORIGINS:
        logging.warning("ALLOWED_ORIGINS is empty; browser clients will be blocked by CORS")
    CORS(
        app,
        resources={r"/api/*": {"origins": ALLOWED_ORIGINS}},
        allow_headers=["Content-Type", "Authorization", "x-api-key", "x-supabase-access-token"],
        methods=["GET", "POST", "OPTIONS"],
        max_age=600,
    )
    app.before_request(require_api_key)

    snapshot_service = SpendingSnapshotService()
    app.config["snapshot_service"] = snapshot_service
    app.config["chat_service"] = ChatService(
        generate_reply=generate_llm_reply,
        get_detailed_snapshot=snapshot_service.get_cached_snapshot,
    )
    app.config["predict_service"] = PredictService(generate_reply=generate_llm_reply)

    app.register_blueprint(plaid_bp)
    app.register_blueprint(ai_bp)
    app.register_blueprint(system_bp)
    return app
