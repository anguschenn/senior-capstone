"""Plaid webhook receiver.

Lives outside /api/ on purpose: Plaid cannot send x-api-key, so require_api_key() must not
apply. Authenticity comes from the Plaid-Verification JWT instead (see plaid_webhook.py).
Replies within Plaid's 10-second window and does the real work on a background thread.
"""

import json

from flask import Blueprint, current_app, jsonify, request

from plaid_webhook import executor, verify_plaid_webhook
from sync_jobs import sync_item_from_webhook

webhook_bp = Blueprint("webhooks", __name__)


@webhook_bp.route("/plaid/webhook", methods=["POST"])
def plaid_webhook():
    body = request.get_data(cache=True)
    ok, reason = verify_plaid_webhook(body, request.headers.get("Plaid-Verification"))
    if not ok:
        print(f"[plaid-webhook] rejected: {reason}")
        return jsonify({"error": "Invalid webhook"}), 401

    try:
        payload = json.loads(body or b"{}")
    except ValueError:
        return jsonify({"error": "Invalid JSON"}), 400

    webhook_type = payload.get("webhook_type")
    webhook_code = payload.get("webhook_code")
    item_id = payload.get("item_id")
    print(f"[plaid-webhook] {webhook_type}/{webhook_code} item_id={item_id}")

    if webhook_type == "TRANSACTIONS" and webhook_code == "SYNC_UPDATES_AVAILABLE" and item_id:
        executor.submit(sync_item_from_webhook, item_id, current_app.config["snapshot_service"])
    elif webhook_type == "ITEM":
        # WEBHOOK_UPDATE_ACKNOWLEDGED confirms a webhook URL change; ERROR / PENDING_EXPIRATION /
        # PENDING_DISCONNECT mean the user must re-authenticate. Logged only for now.
        error_code = (payload.get("error") or {}).get("error_code")
        if error_code:
            print(f"[plaid-webhook] item_id={item_id} error_code={error_code}")

    return jsonify({"received": True}), 200
