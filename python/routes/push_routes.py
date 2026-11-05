"""Authenticated endpoints for browser push subscriptions."""

from flask import Blueprint, jsonify, request

from api.http_helpers import log_route_error
from auth import UserAuthError, require_supabase_user_id
from push_notifications import (
    process_user_notifications,
    public_push_config,
    remove_subscription,
    save_subscription,
)

push_bp = Blueprint("push", __name__)
_MAX_SUBSCRIPTION_BODY_BYTES = 16_384


@push_bp.route("/api/push/config", methods=["GET"])
def push_config():
    try:
        require_supabase_user_id()
        return jsonify(public_push_config())
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except Exception as error:
        log_route_error("/api/push/config unexpected", error)
        return jsonify({"error": "Failed to load push configuration"}), 500


@push_bp.route("/api/push/subscriptions", methods=["POST", "DELETE"])
def push_subscription():
    if request.content_length and request.content_length > _MAX_SUBSCRIPTION_BODY_BYTES:
        return jsonify({"error": "Request body is too large"}), 413
    try:
        user_id = require_supabase_user_id()
        body = request.get_json(silent=True)
        if not isinstance(body, dict):
            return jsonify({"error": "A JSON request body is required"}), 400
        endpoint = body.get("endpoint")
        if request.method == "DELETE":
            try:
                remove_subscription(user_id, endpoint)
            except ValueError as error:
                return jsonify({"error": str(error)}), 400
            return jsonify({"ok": True})

        try:
            save_subscription(user_id, body.get("subscription"))
        except ValueError as error:
            return jsonify({"error": str(error)}), 400
        try:
            process_user_notifications(user_id)
        except Exception as error:
            log_route_error("/api/push/subscriptions delivery", error)
        return jsonify({"ok": True}), 201
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except Exception as error:
        log_route_error("/api/push/subscriptions unexpected", error)
        return jsonify({"error": "Failed to update push subscription"}), 500
