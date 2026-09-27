"""Server-computed budget progress (see budget_progress.py)."""

import datetime as dt
import re

from flask import Blueprint, jsonify, request

from api.http_helpers import log_route_error
from auth import UserAuthError, require_supabase_user_id
from budget_progress import compute_budget_progress

budget_bp = Blueprint("budgets", __name__)
_MONTH_RE = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")


@budget_bp.route("/api/budget_progress", methods=["GET"])
def get_budget_progress():
    """?month=YYYY-MM (default: current month, server time). Should match the Budget page."""
    try:
        user_id = require_supabase_user_id()
        month = request.args.get("month") or dt.date.today().strftime("%Y-%m")
        if not _MONTH_RE.match(month):
            return jsonify({"error": "month must be YYYY-MM"}), 400
        return jsonify({"month": month, "progress": compute_budget_progress(user_id, month)})
    except UserAuthError as error:
        return jsonify({"error": str(error)}), 401
    except Exception as error:
        log_route_error("/api/budget_progress unexpected", error)
        return jsonify({"error": "Internal server error"}), 500
