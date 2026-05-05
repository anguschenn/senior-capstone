import base64
import datetime as dt
import json
import os
import time
from functools import wraps

import jwt as pyjwt
import plaid
from dotenv import load_dotenv
from flask import Flask, g, jsonify, request
from flask_cors import CORS
from plaid.api import plaid_api
from plaid.model.accounts_balance_get_request import AccountsBalanceGetRequest
from plaid.model.accounts_get_request import AccountsGetRequest
from plaid.model.country_code import CountryCode
from plaid.model.item_public_token_exchange_request import ItemPublicTokenExchangeRequest
from plaid.model.link_token_create_request import LinkTokenCreateRequest
from plaid.model.link_token_create_request_user import LinkTokenCreateRequestUser
from plaid.model.products import Products
from plaid.model.transactions_sync_request import TransactionsSyncRequest
from plaid.model.webhook_verification_key_get_request import WebhookVerificationKeyGetRequest
from supabase import create_client

load_dotenv()

# ------------------------------------------------------------------ #
#  App init                                                            #
# ------------------------------------------------------------------ #

app = Flask(__name__)

# Restrict CORS to known Flutter/web origins — never use "*" with credentials
_raw_origins = os.getenv("ALLOWED_ORIGINS", "http://localhost:3000,http://localhost:8080")
ALLOWED_ORIGINS = [o.strip() for o in _raw_origins.split(",") if o.strip()]
CORS(app, origins=ALLOWED_ORIGINS, supports_credentials=True)

# ------------------------------------------------------------------ #
#  Supabase                                                            #
# ------------------------------------------------------------------ #

supabase = create_client(
    os.getenv("SUPABASE_URL"),
    os.getenv("SUPABASE_KEY"),   # service_role key — backend only, never sent to client
)

SUPABASE_JWT_SECRET = os.getenv("SUPABASE_JWT_SECRET")

# ------------------------------------------------------------------ #
#  Auth middleware                                                      #
# ------------------------------------------------------------------ #

def require_auth(f):
    """Validate Supabase JWT and set g.user_id. Rejects all unauthenticated requests."""
    @wraps(f)
    def decorated(*args, **kwargs):
        auth_header = request.headers.get("Authorization", "")
        if not auth_header.startswith("Bearer "):
            return jsonify({"error": "Missing or malformed Authorization header"}), 401
        token = auth_header[7:]
        try:
            payload = pyjwt.decode(
                token,
                SUPABASE_JWT_SECRET,
                algorithms=["HS256"],
                options={"verify_aud": False},  # Supabase uses "authenticated" audience
            )
            g.user_id = payload["sub"]  # Supabase user UUID
        except pyjwt.ExpiredSignatureError:
            return jsonify({"error": "Token expired"}), 401
        except pyjwt.InvalidTokenError:
            return jsonify({"error": "Invalid token"}), 401
        return f(*args, **kwargs)
    return decorated

# ------------------------------------------------------------------ #
#  Plaid client                                                        #
# ------------------------------------------------------------------ #

PLAID_CLIENT_ID     = os.getenv("PLAID_CLIENT_ID")
PLAID_SECRET        = os.getenv("PLAID_SECRET")
PLAID_ENV           = os.getenv("PLAID_ENV", "sandbox")
PLAID_PRODUCTS      = os.getenv("PLAID_PRODUCTS", "transactions").split(",")
PLAID_COUNTRY_CODES = os.getenv("PLAID_COUNTRY_CODES", "US").split(",")
PLAID_REDIRECT_URI  = os.getenv("PLAID_REDIRECT_URI") or None

_host_map = {
    "sandbox":    plaid.Environment.Sandbox,
    "development": plaid.Environment.Development,
    "production": plaid.Environment.Production,
}
host = _host_map.get(PLAID_ENV, plaid.Environment.Sandbox)

configuration = plaid.Configuration(
    host=host,
    api_key={
        "clientId":    PLAID_CLIENT_ID,
        "secret":      PLAID_SECRET,
        "plaidVersion": "2020-09-14",
    },
)
plaid_client = plaid_api.PlaidApi(plaid.ApiClient(configuration))
products = [Products(p.strip()) for p in PLAID_PRODUCTS]

# ------------------------------------------------------------------ #
#  Plaid item helpers (per-user, no global state)                      #
# ------------------------------------------------------------------ #

def _get_plaid_item(user_id: str) -> dict | None:
    """Return the most recent plaid_items row for this user, or None."""
    result = (
        supabase.table("plaid_items")
        .select("id, access_token, item_id, cursor")
        .eq("user_id", user_id)
        .order("created_at", desc=True)
        .limit(1)
        .execute()
    )
    return result.data[0] if result.data else None


def _require_plaid_item(user_id: str):
    """Return plaid item or raise a 400 JSON response."""
    item = _get_plaid_item(user_id)
    if not item:
        raise _PlaidItemMissing()
    return item


class _PlaidItemMissing(Exception):
    pass


# Decorator that injects plaid_item into the route as a kwarg
def require_plaid_item(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        try:
            kwargs["plaid_item"] = _require_plaid_item(g.user_id)
        except _PlaidItemMissing:
            return jsonify({"error": "No bank account connected. Complete Plaid Link first."}), 400
        return f(*args, **kwargs)
    return decorated

# ------------------------------------------------------------------ #
#  Supabase sync helpers                                               #
# ------------------------------------------------------------------ #

def _save_accounts(user_id: str, plaid_item_id: str, access_token: str) -> int:
    response = plaid_client.accounts_get(
        AccountsGetRequest(access_token=access_token)
    ).to_dict()
    accounts = response.get("accounts", [])

    rows = []
    for a in accounts:
        bal = a.get("balances", {})
        rows.append({
            "plaid_item_id":     plaid_item_id,
            "user_id":           user_id,
            "plaid_account_id":  a.get("account_id"),
            "name":              a.get("name"),
            "official_name":     a.get("official_name"),
            "account_type":      str(a.get("type", "")),
            "subtype":           str(a.get("subtype", "")),
            "current_balance":   bal.get("current"),
            "available_balance": bal.get("available"),
            "mask":              a.get("mask"),
            "updated_at":        dt.datetime.now().isoformat(),
        })

    if rows:
        supabase.table("accounts").upsert(rows, on_conflict="plaid_account_id").execute()
    return len(rows)


def _sync_transactions(user_id: str, plaid_item_id: str, access_token: str) -> dict:
    # Load stored cursor for delta-only fetches
    cursor = ""
    item_row = supabase.table("plaid_items").select("cursor").eq("id", plaid_item_id).execute()
    if item_row.data and item_row.data[0].get("cursor"):
        cursor = item_row.data[0]["cursor"]

    added, modified, removed = [], [], []
    has_more = True

    while has_more:
        response = plaid_client.transactions_sync(
            TransactionsSyncRequest(access_token=access_token, cursor=cursor)
        ).to_dict()
        cursor = response["next_cursor"]

        if cursor == "":
            time.sleep(2)
            continue

        added.extend(response["added"])
        modified.extend(response["modified"])
        removed.extend(response["removed"])
        has_more = response["has_more"]

    if added:
        rows = []
        for t in added:
            pfc    = t.get("personal_finance_category") or {}
            loc    = t.get("location") or {}
            amount = t.get("amount", 0)
            confidence = pfc.get("confidence_level", "")
            rows.append({
                "plaid_account_id":     t.get("account_id"),
                "user_id":              user_id,
                "plaid_transaction_id": t.get("transaction_id"),
                "amount":               amount,
                "amount_abs":           abs(amount),
                "is_debit":             amount > 0,
                "date":                 str(t.get("date")),
                "name":                 t.get("name"),
                "merchant_name":        t.get("merchant_name"),
                "category":             (t.get("category") or [None])[0],
                "pfc_primary":          pfc.get("primary"),
                "pfc_detailed":         pfc.get("detailed"),
                "pfc_confidence":       confidence,
                "pending":              t.get("pending", False),
                "location_city":        loc.get("city"),
                "location_region":      loc.get("region"),
                "location_lat":         loc.get("lat"),
                "location_lon":         loc.get("lon"),
                # Flag low-confidence transactions for AI review
                "needs_review":         confidence == "LOW",
                "category_source":      "plaid",
            })
        supabase.table("transactions").upsert(rows, on_conflict="plaid_transaction_id").execute()

    for t in modified:
        pfc    = t.get("personal_finance_category") or {}
        amount = t.get("amount", 0)
        supabase.table("transactions").update({
            "amount":       amount,
            "amount_abs":   abs(amount),
            "is_debit":     amount > 0,
            "pending":      t.get("pending"),
            "pfc_primary":  pfc.get("primary"),
            "pfc_detailed": pfc.get("detailed"),
        }).eq("plaid_transaction_id", t.get("transaction_id")).execute()

    for t in removed:
        supabase.table("transactions").delete().eq(
            "plaid_transaction_id", t.get("transaction_id")
        ).execute()

    supabase.table("plaid_items").update({
        "cursor":         cursor,
        "last_synced_at": dt.datetime.now().isoformat(),
    }).eq("id", plaid_item_id).execute()

    return {"added": len(added), "modified": len(modified), "removed": len(removed)}

# ------------------------------------------------------------------ #
#  Routes — Plaid Link                                                 #
# ------------------------------------------------------------------ #

@app.route("/api/create_link_token", methods=["POST"])
@require_auth
def create_link_token():
    try:
        link_req = LinkTokenCreateRequest(
            products=products,
            client_name="SmartSpend",
            country_codes=[CountryCode(c.strip()) for c in PLAID_COUNTRY_CODES],
            language="en",
            user=LinkTokenCreateRequestUser(client_user_id=g.user_id),
        )
        if PLAID_REDIRECT_URI:
            link_req["redirect_uri"] = PLAID_REDIRECT_URI

        response = plaid_client.link_token_create(link_req)
        return jsonify({"link_token": response.to_dict()["link_token"]})
    except plaid.ApiException as e:
        return jsonify({"error": _plaid_error(e)}), 400


@app.route("/api/set_access_token", methods=["POST"])
@require_auth
def set_access_token():
    """
    Exchange a Plaid Link public_token for an access_token.
    Stores the item server-side; access_token is never returned to the client.
    """
    body = request.get_json(silent=True) or {}
    public_token = body.get("public_token") or request.form.get("public_token")
    if not public_token:
        return jsonify({"error": "public_token is required"}), 400

    try:
        exchange = plaid_client.item_public_token_exchange(
            ItemPublicTokenExchangeRequest(public_token=public_token)
        )
        access_token = exchange["access_token"]
        item_id      = exchange["item_id"]

        # Upsert item — on conflict with item_id (unique), refresh access_token
        result = supabase.table("plaid_items").upsert({
            "user_id":      g.user_id,
            "access_token": access_token,  # stored server-side only
            "item_id":      item_id,
        }, on_conflict="item_id").execute()

        plaid_item_id = result.data[0]["id"]

        # Immediately sync accounts so plaid_account_ids are available
        _save_accounts(g.user_id, plaid_item_id, access_token)

        # Return only non-sensitive identifiers
        return jsonify({"item_id": item_id, "status": "connected"})
    except plaid.ApiException as e:
        return jsonify({"error": _plaid_error(e)}), 400

# ------------------------------------------------------------------ #
#  Routes — data                                                       #
# ------------------------------------------------------------------ #

@app.route("/api/transactions", methods=["GET"])
@require_auth
@require_plaid_item
def get_transactions(plaid_item=None):
    try:
        stats = _sync_transactions(g.user_id, plaid_item["id"], plaid_item["access_token"])

        page  = int(request.args.get("page", 1))
        limit = min(int(request.args.get("limit", 50)), 200)
        offset = (page - 1) * limit

        data = (
            supabase.table("transactions")
            .select("*")
            .eq("user_id", g.user_id)
            .order("date", desc=True)
            .range(offset, offset + limit - 1)
            .execute()
        )
        return jsonify({"transactions": data.data, "sync": stats, "page": page})
    except plaid.ApiException as e:
        return jsonify({"error": _plaid_error(e)}), 400
    except Exception as e:
        import traceback
        traceback.print_exc()
        return jsonify({"error": str(e)}), 500


@app.route("/api/accounts", methods=["GET"])
@require_auth
@require_plaid_item
def get_accounts(plaid_item=None):
    try:
        _save_accounts(g.user_id, plaid_item["id"], plaid_item["access_token"])
        data = (
            supabase.table("accounts")
            .select("*")
            .eq("user_id", g.user_id)
            .execute()
        )
        return jsonify({"accounts": data.data})
    except plaid.ApiException as e:
        return jsonify({"error": _plaid_error(e)}), 400


@app.route("/api/balance", methods=["GET"])
@require_auth
@require_plaid_item
def get_balance(plaid_item=None):
    try:
        response = plaid_client.accounts_balance_get(
            AccountsBalanceGetRequest(access_token=plaid_item["access_token"])
        )
        # Return only balances — not the full Plaid response which may contain sensitive fields
        accounts = response.to_dict().get("accounts", [])
        safe = [
            {
                "account_id":        a.get("account_id"),
                "name":              a.get("name"),
                "mask":              a.get("mask"),
                "type":              str(a.get("type", "")),
                "subtype":           str(a.get("subtype", "")),
                "current_balance":   (a.get("balances") or {}).get("current"),
                "available_balance": (a.get("balances") or {}).get("available"),
            }
            for a in accounts
        ]
        return jsonify({"accounts": safe})
    except plaid.ApiException as e:
        return jsonify({"error": _plaid_error(e)}), 400

# ------------------------------------------------------------------ #
#  Routes — categorization                                             #
# ------------------------------------------------------------------ #

@app.route("/api/transactions/categorize", methods=["POST"])
@require_auth
def categorize_transaction():
    body = request.get_json(silent=True) or {}
    transaction_id = body.get("transaction_id")
    category_id    = body.get("category_id")
    merchant_name  = body.get("merchant_name")

    if not transaction_id or not category_id:
        return jsonify({"error": "transaction_id and category_id are required"}), 400

    # Verify the transaction belongs to this user before updating
    check = (
        supabase.table("transactions")
        .select("id")
        .eq("id", transaction_id)
        .eq("user_id", g.user_id)
        .execute()
    )
    if not check.data:
        return jsonify({"error": "Transaction not found"}), 404

    supabase.table("transactions").update({
        "custom_category_id": category_id,
        "category_source":    "user",
        "needs_review":       False,
    }).eq("id", transaction_id).execute()

    if merchant_name:
        # Teach the system; retroactively fix unreviewed past transactions from same merchant
        supabase.table("merchant_category_rules").upsert({
            "user_id":       g.user_id,
            "merchant_name": merchant_name,
            "category_id":   category_id,
        }, on_conflict="user_id, merchant_name").execute()

        supabase.table("transactions").update({
            "custom_category_id": category_id,
            "category_source":    "user",
        }).eq("user_id", g.user_id).eq("merchant_name", merchant_name).eq(
            "category_source", "plaid"
        ).execute()

    return jsonify({"status": "ok"})

# ------------------------------------------------------------------ #
#  Routes — webhooks                                                   #
# ------------------------------------------------------------------ #

@app.route("/api/webhook", methods=["POST"])
def plaid_webhook():
    """
    Receives Plaid webhook events (e.g. TRANSACTIONS_SYNC_UPDATES_AVAILABLE).
    Verifies the Plaid-Verification JWT before processing.
    See: https://plaid.com/docs/api/webhooks/webhook-verification/
    """
    verification_header = request.headers.get("Plaid-Verification")
    if not verification_header:
        return jsonify({"error": "Missing Plaid-Verification header"}), 400

    if not _verify_plaid_webhook(verification_header, request.get_data()):
        return jsonify({"error": "Webhook verification failed"}), 401

    body = request.get_json(silent=True) or {}
    webhook_type = body.get("webhook_type")
    webhook_code = body.get("webhook_code")
    item_id      = body.get("item_id")

    if webhook_type == "TRANSACTIONS" and webhook_code in (
        "SYNC_UPDATES_AVAILABLE", "INITIAL_UPDATE", "HISTORICAL_UPDATE"
    ):
        # Look up the item and trigger a sync
        item_row = (
            supabase.table("plaid_items")
            .select("id, user_id, access_token")
            .eq("item_id", item_id)
            .execute()
        )
        if item_row.data:
            row = item_row.data[0]
            try:
                _sync_transactions(row["user_id"], row["id"], row["access_token"])
            except Exception as e:
                print(f"Webhook sync error for item {item_id}: {e}")

    return jsonify({"status": "ok"})


def _verify_plaid_webhook(token: str, body: bytes) -> bool:
    """
    Verify a Plaid webhook JWT.
    Fetches Plaid's public key by kid, verifies the JWT, then checks
    the body hash matches the `request_body_sha256` claim.
    """
    import hashlib
    import jose.jwt as jose_jwt
    from jose import JWTError

    try:
        # Decode header without verification to get kid
        unverified = jose_jwt.get_unverified_header(token)
        kid = unverified.get("kid")
        if not kid:
            return False

        # Fetch Plaid's public key for this kid
        key_response = plaid_client.webhook_verification_key_get(
            WebhookVerificationKeyGetRequest(key_id=kid)
        ).to_dict()
        key = key_response.get("key")
        if not key:
            return False

        # Verify the JWT (raises on failure)
        claims = jose_jwt.decode(token, key, algorithms=["ES256"])

        # Verify body hash
        body_hash = hashlib.sha256(body).hexdigest()
        if claims.get("request_body_sha256") != body_hash:
            return False

        return True
    except (JWTError, Exception):
        return False

# ------------------------------------------------------------------ #
#  Health check (no auth — used by deploy platforms)                  #
# ------------------------------------------------------------------ #

@app.route("/healthz", methods=["GET"])
def healthz():
    return jsonify({"status": "ok", "env": PLAID_ENV})

# ------------------------------------------------------------------ #
#  Error helpers                                                       #
# ------------------------------------------------------------------ #

def _plaid_error(e: plaid.ApiException) -> dict:
    try:
        body = json.loads(e.body)
        return {
            "display_message": body.get("error_message"),
            "error_code":      body.get("error_code"),
            "error_type":      body.get("error_type"),
        }
    except Exception:
        return {"display_message": "An unexpected error occurred"}


if __name__ == "__main__":
    app.run(port=int(os.getenv("PORT", 8000)), debug=os.getenv("FLASK_DEBUG", "false").lower() == "true")
