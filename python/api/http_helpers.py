"""Shared HTTP helpers for Flask routes."""

import plaid
from flask import jsonify

from plaid_sync import IdentityStateError, format_error


def identity_error_response(error: IdentityStateError, route_name: str):
    reason = getattr(error, "reason", "")
    print(f"{route_name} identity error: {reason}: {type(error).__name__}")
    if reason == IdentityStateError.STORED_ITEM_NOT_FOUND:
        return jsonify({
            "error": "No connected Plaid item for current user",
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


def plaid_error_response(error: plaid.ApiException):
    status_code = error.status if isinstance(error.status, int) and 400 <= error.status <= 599 else 502
    return jsonify(format_error(error)), status_code


def log_route_error(route_name: str, error: Exception) -> None:
    print(f"{route_name} error: {type(error).__name__}: {error}")
