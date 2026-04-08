# Read env vars from .env file
import base64
import hmac
import os
import datetime as dt
import json
import ssl
import time
import threading
import urllib.error
import urllib.request

from dotenv import load_dotenv
from flask import Flask, request, jsonify
import plaid
from plaid.model.products import Products
from plaid.model.country_code import CountryCode
from plaid.model.item_public_token_exchange_request import ItemPublicTokenExchangeRequest
from plaid.model.link_token_create_request import LinkTokenCreateRequest
from plaid.model.link_token_create_request_user import LinkTokenCreateRequestUser
from plaid.model.asset_report_create_request import AssetReportCreateRequest
from plaid.model.asset_report_create_request_options import AssetReportCreateRequestOptions
from plaid.model.asset_report_user import AssetReportUser
from plaid.model.asset_report_get_request import AssetReportGetRequest
from plaid.model.asset_report_pdf_get_request import AssetReportPDFGetRequest
from plaid.model.auth_get_request import AuthGetRequest
from plaid.model.transactions_sync_request import TransactionsSyncRequest
from plaid.model.accounts_balance_get_request import AccountsBalanceGetRequest
from plaid.model.accounts_get_request import AccountsGetRequest
from plaid.model.item_get_request import ItemGetRequest
from plaid.model.institutions_get_by_id_request import InstitutionsGetByIdRequest
from plaid.api import plaid_api

from supabase import create_client

load_dotenv()

# ------------------------------------------------------------------ #
#  App + Supabase init (must be after load_dotenv)                    #
# ------------------------------------------------------------------ #
app = Flask(__name__)

supabase = create_client(
    os.getenv("SUPABASE_URL"),
    os.getenv("SUPABASE_KEY")
)

# ------------------------------------------------------------------ #
#  Plaid config                                                        #
# ------------------------------------------------------------------ #
PLAID_CLIENT_ID    = os.getenv('PLAID_CLIENT_ID')
PLAID_SECRET       = os.getenv('PLAID_SECRET')
PLAID_ENV          = os.getenv('PLAID_ENV', 'sandbox')
PLAID_PRODUCTS     = os.getenv('PLAID_PRODUCTS', 'transactions').split(',')
PLAID_COUNTRY_CODES = os.getenv('PLAID_COUNTRY_CODES', 'US').split(',')

def empty_to_none(field):
    value = os.getenv(field)
    if value is None or len(value) == 0:
        return None
    return value

GEMINI_API_KEY = empty_to_none('GEMINI_API_KEY')
GEMINI_MODEL = os.getenv('GEMINI_MODEL', 'gemini-2.0-flash')

try:
    import certifi
except Exception:
    certifi = None

host = plaid.Environment.Sandbox
if PLAID_ENV == 'production':
    host = plaid.Environment.Production

PLAID_REDIRECT_URI = empty_to_none('PLAID_REDIRECT_URI')

configuration = plaid.Configuration(
    host=host,
    api_key={
        'clientId': PLAID_CLIENT_ID,
        'secret':   PLAID_SECRET,
        'plaidVersion': '2020-09-14'
    }
)

api_client = plaid.ApiClient(configuration)
client     = plaid_api.PlaidApi(api_client)

products = [Products(p) for p in PLAID_PRODUCTS]

# Demo identity is configurable via env; no hardcoded IDs in route handlers.
DEMO_USER_ID = empty_to_none('DEMO_USER_ID')
DEMO_PLAID_ITEM_ID = empty_to_none('DEMO_PLAID_ITEM_ID')
INTERNAL_API_KEY = empty_to_none('INTERNAL_API_KEY')
SPENDING_SNAPSHOT_CACHE_TTL_SECONDS = int(
    os.getenv("SPENDING_SNAPSHOT_CACHE_TTL_SECONDS", "60")
)
_SPENDING_SNAPSHOT_CACHE = {}
_SPENDING_SNAPSHOT_CACHE_LOCK = threading.Lock()


def _require_demo_identity():
    if not DEMO_USER_ID or not DEMO_PLAID_ITEM_ID:
        raise RuntimeError(
            "Missing DEMO_USER_ID or DEMO_PLAID_ITEM_ID. "
            "Set both in python/.env."
        )
    return DEMO_USER_ID, DEMO_PLAID_ITEM_ID


def _get_stored_item_credentials():
    user_id, plaid_item_id = _require_demo_identity()
    row = supabase.table("plaid_items") \
        .select("access_token,item_id") \
        .eq("id", plaid_item_id) \
        .eq("user_id", user_id) \
        .limit(1) \
        .execute()

    if not row.data:
        raise RuntimeError("No stored plaid_items record for configured demo identity")

    record = row.data[0]
    access_token = record.get("access_token")
    item_id = record.get("item_id")
    if not access_token:
        raise RuntimeError("Stored Plaid access token is missing")
    return access_token, item_id


def _generate_gemini_reply(prompt):
    if not GEMINI_API_KEY:
        raise RuntimeError("Missing GEMINI_API_KEY")
    endpoint = (
        f"https://generativelanguage.googleapis.com/v1beta/models/"
        f"{GEMINI_MODEL}:generateContent?key={GEMINI_API_KEY}"
    )
    payload = {
        "contents": [
            {
                "role": "user",
                "parts": [{"text": prompt}]
            }
        ]
    }
    req = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    ssl_context = ssl.create_default_context()
    if certifi is not None:
        ssl_context.load_verify_locations(cafile=certifi.where())
    with urllib.request.urlopen(req, timeout=20, context=ssl_context) as response:
        raw = response.read().decode("utf-8")
        parsed = json.loads(raw)
    candidates = parsed.get("candidates") or []
    if not candidates:
        raise RuntimeError("Gemini returned no candidates")
    content = (candidates[0] or {}).get("content") or {}
    parts = content.get("parts") or []
    if not parts:
        raise RuntimeError("Gemini returned empty content")
    text = (parts[0] or {}).get("text") or ""
    if not text.strip():
        raise RuntimeError("Gemini returned blank reply")
    return text


def _build_spending_snapshot(user_id):
    rows = supabase.table("transactions") \
        .select("date,amount,merchant_name,name,pfc_primary,pfc_detailed,pending") \
        .eq("user_id", user_id) \
        .order("date", desc=True) \
        .limit(400) \
        .execute()

    txs = rows.data or []
    if not txs:
        return "No transactions available."

    today = dt.date.today()
    cutoff = today - dt.timedelta(days=30)
    income_30d = 0.0
    expense_30d = 0.0
    category_totals = {}
    recent_lines = []

    for row in txs:
        raw_date = row.get("date")
        parsed_date = dt.date.today()
        if isinstance(raw_date, str):
            try:
                parsed_date = dt.datetime.fromisoformat(raw_date[:10]).date()
            except Exception:
                parsed_date = dt.date.today()

        raw_amount = row.get("amount")
        amount = raw_amount if isinstance(raw_amount, (int, float)) else 0.0
        amount = float(amount)

        if parsed_date >= cutoff:
            if amount < 0:
                income_30d += abs(amount)
            else:
                expense_30d += amount
                detailed = (row.get("pfc_detailed") or "").strip()
                primary = (row.get("pfc_primary") or "").strip()
                category = detailed or primary or "Uncategorized"
                category_totals[category] = category_totals.get(category, 0.0) + amount

        if len(recent_lines) < 12:
            merchant = (row.get("merchant_name") or "").strip()
            fallback_name = (row.get("name") or "").strip()
            label = merchant or fallback_name or "Unknown merchant"
            direction = "income" if amount < 0 else "expense"
            recent_lines.append(
                f"- {parsed_date.isoformat()} | {label} | {direction} | ${abs(amount):.2f}"
            )

    top_categories = sorted(
        category_totals.items(),
        key=lambda item: item[1],
        reverse=True,
    )[:5]
    if top_categories:
        top_category_text = "\n".join(
            f"- {name}: ${total:.2f}" for name, total in top_categories
        )
    else:
        top_category_text = "- No expense categories in last 30 days."

    return (
        f"Snapshot window: last 30 days ending {today.isoformat()}\n"
        f"- Total income (30d): ${income_30d:.2f}\n"
        f"- Total expenses (30d): ${expense_30d:.2f}\n"
        f"- Net cash flow (30d): ${income_30d - expense_30d:.2f}\n"
        "Top expense categories (30d):\n"
        f"{top_category_text}\n"
        "Recent transactions:\n"
        f"{chr(10).join(recent_lines)}"
    )


def _invalidate_spending_snapshot_cache(user_id):
    with _SPENDING_SNAPSHOT_CACHE_LOCK:
        _SPENDING_SNAPSHOT_CACHE.pop(user_id, None)


def _get_cached_spending_snapshot(user_id):
    now_ts = time.time()
    with _SPENDING_SNAPSHOT_CACHE_LOCK:
        entry = _SPENDING_SNAPSHOT_CACHE.get(user_id)
        if entry and entry.get("expires_at", 0) > now_ts:
            return entry.get("value")

    snapshot = _build_spending_snapshot(user_id)
    expires_at = now_ts + max(1, SPENDING_SNAPSHOT_CACHE_TTL_SECONDS)
    with _SPENDING_SNAPSHOT_CACHE_LOCK:
        _SPENDING_SNAPSHOT_CACHE[user_id] = {
            "value": snapshot,
            "expires_at": expires_at,
        }
    return snapshot


def _clamp_str(value, max_len):
    if not isinstance(value, str):
        return ""
    return value.strip()[:max_len]


def _to_float(value, default=0.0):
    try:
        if isinstance(value, (int, float)):
            return float(value)
        return float(str(value))
    except Exception:
        return default


def _sanitize_client_spending_summary(summary):
    if not isinstance(summary, dict):
        return None

    cleaned = {}
    cleaned["scope"] = _clamp_str(summary.get("scope", ""), 32)
    cleaned["generated_at"] = _clamp_str(summary.get("generated_at", ""), 40)
    window_days = int(_to_float(summary.get("window_days", 30), 30))
    cleaned["window_days"] = max(1, min(window_days, 90))

    totals = summary.get("totals")
    if isinstance(totals, dict):
        cleaned["totals"] = {
            "income_30d": max(0.0, _to_float(totals.get("income_30d", 0))),
            "expenses_30d": max(0.0, _to_float(totals.get("expenses_30d", 0))),
            "net_30d": _to_float(totals.get("net_30d", 0)),
            "tx_count_30d": max(0, int(_to_float(totals.get("tx_count_30d", 0)))),
            "expense_tx_count_30d": max(0, int(_to_float(totals.get("expense_tx_count_30d", 0)))),
            "income_month": max(0.0, _to_float(totals.get("income_month", 0))),
            "expenses_month": max(0.0, _to_float(totals.get("expenses_month", 0))),
            "net_month": _to_float(totals.get("net_month", 0)),
        }

    cleaned_categories = []
    categories = summary.get("top_expense_categories")
    if isinstance(categories, list):
        for item in categories[:5]:
            if not isinstance(item, dict):
                continue
            name = _clamp_str(item.get("category", ""), 64)
            amount = max(0.0, _to_float(item.get("amount", 0)))
            if not name:
                continue
            cleaned_categories.append({
                "category": name,
                "amount": amount,
            })
    cleaned["top_expense_categories"] = cleaned_categories

    cleaned_recent = []
    recent = summary.get("recent_transactions")
    if isinstance(recent, list):
        for item in recent[:5]:
            if not isinstance(item, dict):
                continue
            date = _clamp_str(item.get("date", ""), 16)
            name = _clamp_str(item.get("name", ""), 80)
            category = _clamp_str(item.get("category", ""), 64)
            amount = _to_float(item.get("amount", 0))
            if not name:
                continue
            cleaned_recent.append({
                "date": date,
                "name": name,
                "category": category,
                "amount": amount,
            })
    cleaned["recent_transactions"] = cleaned_recent

    cleaned_alerts = []
    alerts = summary.get("budget_alerts")
    if isinstance(alerts, list):
        for item in alerts[:5]:
            if not isinstance(item, dict):
                continue
            category = _clamp_str(item.get("category", ""), 64)
            spent = max(0.0, _to_float(item.get("spent", 0)))
            limit = max(0.0, _to_float(item.get("limit", 0)))
            ratio = max(0.0, _to_float(item.get("ratio", 0)))
            if not category:
                continue
            cleaned_alerts.append({
                "category": category,
                "spent": spent,
                "limit": limit,
                "ratio": ratio,
            })
    cleaned["budget_alerts"] = cleaned_alerts

    has_signal = bool(
        cleaned.get("totals")
        or cleaned_categories
        or cleaned_recent
        or cleaned_alerts
    )
    return cleaned if has_signal else None


def _format_client_summary_for_prompt(summary):
    totals = summary.get("totals") or {}
    categories = summary.get("top_expense_categories") or []
    recent = summary.get("recent_transactions") or []
    alerts = summary.get("budget_alerts") or []
    scope = summary.get("scope", "unknown")
    window_days = summary.get("window_days", 30)

    category_text = "\n".join(
        f"- {c.get('category')}: ${c.get('amount', 0):.2f}" for c in categories
    ) or "- none"
    recent_text = "\n".join(
        f"- {r.get('date')} | {r.get('name')} | ${abs(r.get('amount', 0)):.2f} | {r.get('category') or 'Uncategorized'}"
        for r in recent
    ) or "- none"
    alert_text = "\n".join(
        f"- {a.get('category')}: spent ${a.get('spent', 0):.2f} / limit ${a.get('limit', 0):.2f} (ratio {a.get('ratio', 0):.2f})"
        for a in alerts
    ) or "- none"

    return (
        f"Snapshot source: frontend_summary\n"
        f"- Scope: {scope}\n"
        f"- Window: last {window_days} days\n"
        f"- Income (30d): ${totals.get('income_30d', 0):.2f}\n"
        f"- Expenses (30d): ${totals.get('expenses_30d', 0):.2f}\n"
        f"- Net (30d): ${totals.get('net_30d', 0):.2f}\n"
        f"- Transactions (30d): {totals.get('tx_count_30d', 0)}\n"
        f"- Expense transactions (30d): {totals.get('expense_tx_count_30d', 0)}\n"
        f"- Income (month): ${totals.get('income_month', 0):.2f}\n"
        f"- Expenses (month): ${totals.get('expenses_month', 0):.2f}\n"
        f"- Net (month): ${totals.get('net_month', 0):.2f}\n"
        f"Top expense categories:\n{category_text}\n"
        f"Recent transactions:\n{recent_text}\n"
        f"Budget alerts:\n{alert_text}"
    )


@app.before_request
def require_api_key():
    if not request.path.startswith('/api/'):
        return None
    if not INTERNAL_API_KEY:
        return jsonify({"error": "Server misconfigured"}), 500
    provided = request.headers.get('x-api-key') or ""
    if not hmac.compare_digest(provided, INTERNAL_API_KEY):
        return jsonify({"error": "Unauthorized"}), 401
    return None

# ------------------------------------------------------------------ #
#  Supabase sync helpers                                               #
# ------------------------------------------------------------------ #

def save_accounts_to_supabase(user_id, plaid_item_id, plaid_access_token):
    """Fetch accounts from Plaid and upsert them into Supabase."""
    try:
        response = client.accounts_get(AccountsGetRequest(access_token=plaid_access_token)).to_dict()
        accounts = response.get('accounts', [])

        rows = []
        for a in accounts:
            balances = a.get('balances', {})
            rows.append({
                "plaid_item_id":    plaid_item_id,
                "user_id":          user_id,
                "plaid_account_id": a.get('account_id'),
                "name":             a.get('name'),
                "official_name":    a.get('official_name'),
                "account_type":     str(a.get('type', '')),
                "subtype":          str(a.get('subtype', '')),
                "current_balance":  balances.get('current'),
                "available_balance":balances.get('available'),
                "mask":             a.get('mask'),
                "updated_at":       dt.datetime.now().isoformat(),
            })

        if rows:
            supabase.table("accounts").upsert(
                rows, on_conflict="plaid_account_id"
            ).execute()

        return len(rows)
    except Exception as e:
        print(f"save_accounts_to_supabase error: {e}")
        raise


def sync_transactions_to_supabase(user_id, plaid_item_id, plaid_access_token):
    """
    Pull all new/modified/removed transactions from Plaid using the
    cursor-based /transactions/sync endpoint and persist them to Supabase.
    """
    # Retrieve stored cursor so we only fetch deltas on subsequent calls
    cursor = ''
    try:
        item_row = supabase.table("plaid_items") \
            .select("cursor") \
            .eq("id", plaid_item_id) \
            .execute()
        if item_row.data and item_row.data[0].get("cursor"):
            cursor = item_row.data[0]["cursor"]
    except Exception as e:
        print(f"Could not retrieve cursor: {e}")

    added, modified, removed = [], [], []
    has_more = True

    while has_more:
        sync_request = TransactionsSyncRequest(
            access_token=plaid_access_token,
            cursor=cursor,
        )
        response = client.transactions_sync(sync_request).to_dict()
        cursor = response['next_cursor']

        # Transactions not ready yet — wait and retry
        if cursor == '':
            time.sleep(2)
            continue

        added.extend(response['added'])
        modified.extend(response['modified'])
        removed.extend(response['removed'])
        has_more = response['has_more']

    # --- INSERT new transactions ---
    if added:
        rows = []
        for t in added:
            pfc = t.get('personal_finance_category') or {}
            loc = t.get('location') or {}
            rows.append({
                "plaid_account_id":     t.get('account_id'),
                "user_id":              user_id,
                "plaid_transaction_id": t.get('transaction_id'),
                "amount":               t.get('amount'),
                "date":                 str(t.get('date')),
                "name":                 t.get('name'),
                "merchant_name":        t.get('merchant_name'),
                "category":             (t.get('category') or [None])[0],
                "pfc_primary":          pfc.get('primary'),
                "pfc_detailed":         pfc.get('detailed'),
                "pfc_confidence":       pfc.get('confidence_level'),
                "pending":              t.get('pending', False),
                "location_city":        loc.get('city'),
                "location_region":      loc.get('region'),
                "location_lat":         loc.get('lat'),
                "location_lon":         loc.get('lon'),
            })
        supabase.table("transactions").upsert(
            rows, on_conflict="plaid_transaction_id"
        ).execute()

    # --- UPDATE modified transactions ---
    for t in modified:
        pfc = t.get('personal_finance_category') or {}
        supabase.table("transactions").update({
            "amount":       t.get('amount'),
            "pending":      t.get('pending'),
            "pfc_primary":  pfc.get('primary'),
            "pfc_detailed": pfc.get('detailed'),
        }).eq("plaid_transaction_id", t.get('transaction_id')).execute()

    # --- DELETE removed transactions ---
    for t in removed:
        supabase.table("transactions") \
            .delete() \
            .eq("plaid_transaction_id", t.get('transaction_id')) \
            .execute()

    # --- Save updated cursor for next sync ---
    supabase.table("plaid_items").update({
        "cursor":         cursor,
        "last_synced_at": dt.datetime.now().isoformat(),
    }).eq("id", plaid_item_id).execute()

    return {"added": len(added), "modified": len(modified), "removed": len(removed)}

# ------------------------------------------------------------------ #
#  Routes                                                              #
# ------------------------------------------------------------------ #

@app.route('/api/info', methods=['POST'])
def info():
    has_configured_identity = bool(DEMO_USER_ID and DEMO_PLAID_ITEM_ID)
    has_stored_item = False
    if has_configured_identity:
        try:
            _get_stored_item_credentials()
            has_stored_item = True
        except Exception:
            has_stored_item = False
    return jsonify({
        'products': PLAID_PRODUCTS,
        'plaid_env': PLAID_ENV,
        'has_configured_identity': has_configured_identity,
        'has_stored_item': has_stored_item,
    })


@app.route('/api/create_link_token', methods=['POST'])
def create_link_token():
    try:
        link_request = LinkTokenCreateRequest(
            products=products,
            client_name="SmartSpend",
            country_codes=list(map(lambda x: CountryCode(x), PLAID_COUNTRY_CODES)),
            language='en',
            user=LinkTokenCreateRequestUser(
                client_user_id=str(time.time())
            )
        )
        if PLAID_REDIRECT_URI:
            link_request['redirect_uri'] = PLAID_REDIRECT_URI

        response = client.link_token_create(link_request)
        return jsonify(response.to_dict())
    except plaid.ApiException as e:
        print(e)
        return json.loads(e.body)


@app.route('/api/set_access_token', methods=['POST'])
def get_access_token():
    """
    Exchange a Link public_token for an access_token and save the
    Plaid item + accounts to Supabase.

    Demo user/item row ids are provided via env and used only to scope writes.
    """
    user_id, plaid_item_id = _require_demo_identity()
    body = request.get_json(silent=True) or {}
    public_token = body.get('public_token') or request.form.get('public_token')
    if not public_token:
        return jsonify({"error": "Missing public_token"}), 400
    try:
        exchange_request  = ItemPublicTokenExchangeRequest(public_token=public_token)
        exchange_response = client.item_public_token_exchange(exchange_request)
        access_token      = exchange_response['access_token']
        item_id           = exchange_response['item_id']

        # Persist the item to Supabase
        supabase.table("plaid_items").upsert({
            "id":           plaid_item_id,
            "user_id":      user_id,
            "access_token": access_token,
            "item_id":      item_id,
        }, on_conflict="id").execute()

        # Sync accounts straight away
        save_accounts_to_supabase(user_id, plaid_item_id, access_token)

        return jsonify(exchange_response.to_dict())
    except plaid.ApiException as e:
        return json.loads(e.body)


@app.route('/api/auth', methods=['GET'])
def get_auth():
    try:
        access_token, _ = _get_stored_item_credentials()
        response = client.auth_get(AuthGetRequest(access_token=access_token))
        pretty_print_response(response.to_dict())
        return jsonify(response.to_dict())
    except plaid.ApiException as e:
        return jsonify(format_error(e))


@app.route('/api/transactions', methods=['GET'])
def get_transactions():
    try:
        user_id, plaid_item_id = _require_demo_identity()
        access_token, _ = _get_stored_item_credentials()
        stats = sync_transactions_to_supabase(user_id, plaid_item_id, access_token)
        _invalidate_spending_snapshot_cache(user_id)
        print(f"Sync complete: {stats}")

        data = supabase.table("transactions") \
            .select("*") \
            .eq("user_id", user_id) \
            .order("date", desc=True) \
            .limit(20) \
            .execute()

        # Return both formats — quickstart frontend needs 'latest_transactions'
        return jsonify({
            "latest_transactions": data.data,
            "transactions": data.data,
            "sync": stats
        })
    except plaid.ApiException as e:
        return jsonify(format_error(e))
    except Exception as e:
        print(f"/api/transactions unexpected error: {e}")
        return jsonify({"error": "Internal server error"}), 500

@app.route('/api/balance', methods=['GET'])
def get_balance():
    try:
        access_token, _ = _get_stored_item_credentials()
        response = client.accounts_balance_get(
            AccountsBalanceGetRequest(access_token=access_token)
        )
        pretty_print_response(response.to_dict())
        return jsonify(response.to_dict())
    except plaid.ApiException as e:
        return jsonify(format_error(e))


@app.route('/api/accounts', methods=['GET'])
def get_accounts():
    try:
        access_token, _ = _get_stored_item_credentials()
        response = client.accounts_get(AccountsGetRequest(access_token=access_token))
        pretty_print_response(response.to_dict())
        return jsonify(response.to_dict())
    except plaid.ApiException as e:
        return jsonify(format_error(e))


@app.route('/api/assets', methods=['GET'])
def get_assets():
    try:
        access_token, _ = _get_stored_item_credentials()
        create_req = AssetReportCreateRequest(
            access_tokens=[access_token],
            days_requested=60,
            options=AssetReportCreateRequestOptions(
                webhook='https://www.example.com',
                client_report_id='123',
                user=AssetReportUser(
                    client_user_id='789',
                    first_name='Jane',
                    middle_name='Leah',
                    last_name='Doe',
                    ssn='123-45-6789',
                    phone_number='(555) 123-4567',
                    email='jane.doe@example.com',
                )
            )
        )
        response          = client.asset_report_create(create_req)
        asset_report_token = response['asset_report_token']

        get_req  = AssetReportGetRequest(asset_report_token=asset_report_token)
        response = poll_with_retries(lambda: client.asset_report_get(get_req))
        asset_report_json = response['report']

        pdf_req = AssetReportPDFGetRequest(asset_report_token=asset_report_token)
        pdf     = client.asset_report_pdf_get(pdf_req)

        return jsonify({
            'error': None,
            'json':  asset_report_json.to_dict(),
            'pdf':   base64.b64encode(pdf.read()).decode('utf-8'),
        })
    except plaid.ApiException as e:
        return jsonify(format_error(e))


@app.route('/api/item', methods=['GET'])
def item():
    try:
        access_token, _ = _get_stored_item_credentials()
        response = client.item_get(ItemGetRequest(access_token=access_token))
        inst_response = client.institutions_get_by_id(
            InstitutionsGetByIdRequest(
                institution_id=response['item']['institution_id'],
                country_codes=list(map(lambda x: CountryCode(x), PLAID_COUNTRY_CODES))
            )
        )
        pretty_print_response(response.to_dict())
        pretty_print_response(inst_response.to_dict())
        return jsonify({
            'error':       None,
            'item':        response.to_dict()['item'],
            'institution': inst_response.to_dict()['institution'],
        })
    except plaid.ApiException as e:
        return jsonify(format_error(e))


@app.route('/api/ai/chat', methods=['POST'])
def ai_chat():
    body = request.get_json(silent=True) or {}
    prompt = (body.get("prompt") or "").strip()
    if not prompt:
        return jsonify({"error": "Missing prompt"}), 400
    if len(prompt) > 4000:
        return jsonify({"error": "Prompt too long"}), 400
    try:
        user_id, _ = _require_demo_identity()
        client_summary = _sanitize_client_spending_summary(body.get("spending_summary"))
        if client_summary is not None:
            spending_snapshot = _format_client_summary_for_prompt(client_summary)
            context_source = "frontend_summary"
        else:
            spending_snapshot = _get_cached_spending_snapshot(user_id)
            context_source = "server_snapshot"
        enhanced_prompt = (
            "You are a personal finance assistant for the app user. "
            "Use the provided spending snapshot as the primary context. "
            "Be concise, practical, and specific. If data is missing, say so clearly. "
            "Do not claim access to data outside this snapshot. "
            "Do not ask the user to provide spending data again. "
            "If the snapshot is sparse, still provide best-effort guidance from available fields. "
            "Respond in the same language as the user question.\n\n"
            "Output format:\n"
            "Insights:\n"
            "1) ...\n"
            "2) ...\n"
            "3) ...\n"
            "Actions:\n"
            "1) ...\n"
            "2) ...\n"
            "3) ...\n"
            "Keep each bullet short.\n\n"
            "[SPENDING_SNAPSHOT]\n"
            f"{spending_snapshot}\n\n"
            "[CONTEXT_SOURCE]\n"
            f"{context_source}\n\n"
            "[USER_QUESTION]\n"
            f"{prompt}"
        )
        reply = _generate_gemini_reply(enhanced_prompt)
        return jsonify({"reply": reply, "context_source": context_source})
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8")
        except Exception:
            detail = "<unreadable>"
        print(f"Gemini HTTP error {e.code}: {detail}")
        return jsonify({"error": "Gemini request failed"}), 502
    except Exception as e:
        print(f"/api/ai/chat error: {e}")
        return jsonify({"error": "Internal server error"}), 500


@app.route('/api/ai/ping', methods=['GET'])
def ai_ping():
    try:
        reply = _generate_gemini_reply("Reply with exactly: pong")
        return jsonify({
            "ok": True,
            "model": GEMINI_MODEL,
            "reply_preview": reply[:80],
        })
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8")
        except Exception:
            detail = "<unreadable>"
        return jsonify({
            "ok": False,
            "model": GEMINI_MODEL,
            "error_type": "gemini_http_error",
            "status_code": e.code,
            "detail": detail[:300],
        }), 502
    except Exception as e:
        return jsonify({
            "ok": False,
            "model": GEMINI_MODEL,
            "error_type": "server_error",
            "detail": str(e),
        }), 500


# ------------------------------------------------------------------ #
#  Utilities                                                           #
# ------------------------------------------------------------------ #

def poll_with_retries(request_callback, ms=1000, retries_left=20):
    while retries_left > 0:
        try:
            return request_callback()
        except plaid.ApiException as e:
            response = json.loads(e.body)
            if response['error_code'] != 'PRODUCT_NOT_READY':
                raise e
            retries_left -= 1
            if retries_left == 0:
                raise Exception('Ran out of retries while polling') from e
            time.sleep(ms / 1000)

def pretty_print_response(response):
    print(json.dumps(response, indent=2, sort_keys=True, default=str))

def format_error(e):
    response = json.loads(e.body)
    return {'error': {
        'status_code':     e.status,
        'display_message': response['error_message'],
        'error_code':      response['error_code'],
        'error_type':      response['error_type'],
    }}


if __name__ == '__main__':
    app.run(port=int(os.getenv('PORT', 8000)))
