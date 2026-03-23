# Read env vars from .env file
import base64
import os
import datetime as dt
import json
import time
from datetime import date, timedelta
import uuid

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

# In-memory token storage (sandbox only — Supabase replaces this in production)
access_token = None
item_id      = None

# ------------------------------------------------------------------ #
#  Supabase sync helpers                                               #
# ------------------------------------------------------------------ #

def save_accounts_to_supabase(user_id, plaid_item_id):
    """Fetch accounts from Plaid and upsert them into Supabase."""
    try:
        response = client.accounts_get(AccountsGetRequest(access_token=access_token)).to_dict()
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


def sync_transactions_to_supabase(user_id, plaid_item_id):
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
            access_token=access_token,
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
    return jsonify({
        'item_id':      item_id,
        'access_token': access_token,   # remove before production!
        'products':     PLAID_PRODUCTS,
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

    For sandbox testing, user_id and plaid_item_id are hardcoded below.
    Replace with real values once auth is wired up.
    """
    global access_token, item_id

    # ---- SANDBOX TEST IDs — replace with real auth later ---- #
    TEST_USER_ID      = "e22c81ff-c63d-4f42-a67b-e6812ffed2a3"
    TEST_PLAID_ITEM_ID = "9170e13e-f03c-455a-94a1-00c79d0064ab"
    # ---------------------------------------------------------- #

    public_token = request.form['public_token']
    try:
        exchange_request  = ItemPublicTokenExchangeRequest(public_token=public_token)
        exchange_response = client.item_public_token_exchange(exchange_request)
        access_token      = exchange_response['access_token']
        item_id           = exchange_response['item_id']

        # Persist the item to Supabase
        supabase.table("plaid_items").upsert({
            "id":           TEST_PLAID_ITEM_ID,
            "user_id":      TEST_USER_ID,
            "access_token": access_token,
            "item_id":      item_id,
        }, on_conflict="id").execute()

        # Sync accounts straight away
        save_accounts_to_supabase(TEST_USER_ID, TEST_PLAID_ITEM_ID)

        return jsonify(exchange_response.to_dict())
    except plaid.ApiException as e:
        return json.loads(e.body)


@app.route('/api/auth', methods=['GET'])
def get_auth():
    try:
        response = client.auth_get(AuthGetRequest(access_token=access_token))
        pretty_print_response(response.to_dict())
        return jsonify(response.to_dict())
    except plaid.ApiException as e:
        return jsonify(format_error(e))


@app.route('/api/transactions', methods=['GET'])
def get_transactions():
    TEST_USER_ID       = "e22c81ff-c63d-4f42-a67b-e6812ffed2a3"
    TEST_PLAID_ITEM_ID = "9170e13e-f03c-455a-94a1-00c79d0064ab"

    try:
        stats = sync_transactions_to_supabase(TEST_USER_ID, TEST_PLAID_ITEM_ID)
        print(f"Sync complete: {stats}")

        data = supabase.table("transactions") \
            .select("*") \
            .eq("user_id", TEST_USER_ID) \
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
        return jsonify({"error": str(e)}), 500

@app.route('/api/balance', methods=['GET'])
def get_balance():
    try:
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
        response = client.accounts_get(AccountsGetRequest(access_token=access_token))
        pretty_print_response(response.to_dict())
        return jsonify(response.to_dict())
    except plaid.ApiException as e:
        return jsonify(format_error(e))


@app.route('/api/assets', methods=['GET'])
def get_assets():
    try:
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