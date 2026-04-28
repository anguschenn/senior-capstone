import os
import sys
from datetime import datetime, timezone
 
import requests
from dotenv import load_dotenv
 
# ── Load env ─────────────────────────────────────────────────────────────────
load_dotenv()
 
TELLER_BASE = "https://api.teller.io"
ACCESS_TOKEN = os.environ["TELLER_ACCESS_TOKEN"]

ENV = os.getenv("ENV", "sandbox")
CERT = (
    os.environ["TELLER_CERT_PATH"],
    os.environ["TELLER_KEY_PATH"],
) if ENV != "sandbox" else None

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_KEY"]   # service role key
USER_ID      = os.environ["SMARTSPEND_USER_ID"]

# ── Supabase REST helper ──────────────────────────────────────────────────────
 
SUPABASE_HEADERS = {
    "apikey":        SUPABASE_KEY,
    "Authorization": f"Bearer {SUPABASE_KEY}",
    "Content-Type":  "application/json",
    "Prefer":        "resolution=merge-duplicates",   # upsert behaviour
}
 
 
def sb_upsert(table: str, rows: list[dict]) -> dict:
    """Upsert a list of row dicts into a Supabase table."""
    if not rows:
        return {}
    url = f"{SUPABASE_URL}/rest/v1/{table}"
    resp = requests.post(url, json=rows, headers=SUPABASE_HEADERS)
    if resp.status_code not in (200, 201):
        print(f"  ERROR upserting into {table}: {resp.status_code} {resp.text}")
        resp.raise_for_status()
    return resp.json() if resp.text else {}
 
 # ── Teller API helper ─────────────────────────────────────────────────────────
 
def teller_get(path: str) -> dict | list:
    """GET from Teller API using mTLS + basic auth."""
    resp = requests.get(
        f"{TELLER_BASE}{path}",
        auth=(ACCESS_TOKEN, ""),   # Teller uses access token as basic auth username
        cert=CERT,
    )
    resp.raise_for_status()
    return resp.json()
 
 
# ── Helpers ───────────────────────────────────────────────────────────────────
 
def derive_debit(amount_str: str, account_type: str) -> bool:
    """
    Teller sign convention:
      depository: negative = money OUT (debit), positive = money IN (credit)
      credit:     positive = charge (debit from your perspective), negative = payment
    Returns True if money left the user's pocket.
    """
    amount = float(amount_str)
    if account_type == "depository":
        return amount < 0
    else:  # credit
        return amount > 0
 
 
# ── Main sync ─────────────────────────────────────────────────────────────────
 
def sync():
    now = datetime.now(timezone.utc).isoformat()
 
    # ── 1. Fetch accounts ─────────────────────────────────────────────────────
    print("Fetching accounts from Teller sandbox...")
    accounts_raw = teller_get("/accounts")
    print(f"  Found {len(accounts_raw)} account(s)")
 
    # ── 2. Upsert enrollment ──────────────────────────────────────────────────
    # All sandbox accounts share the same enrollment_id.
    # We take it from the first account.
    if not accounts_raw:
        print("No accounts returned — check your access token.")
        sys.exit(1)
 
    enrollment_id_teller = accounts_raw[0]["enrollment_id"]
    institution          = accounts_raw[0]["institution"]
 
    enrollment_row = {
        "user_id":               USER_ID,
        "teller_enrollment_id":  enrollment_id_teller,
        "access_token":          ACCESS_TOKEN,
        "institution_id":        institution["id"],
        "institution_name":      institution["name"],
        "last_synced_at":        now,
    }
    print(f"\nUpserting enrollment: {enrollment_id_teller}")
    sb_upsert("teller_enrollments", [enrollment_row])
 
    # Fetch the enrollment's UUID from Supabase so we can FK against it
    enr_resp = requests.get(
        f"{SUPABASE_URL}/rest/v1/teller_enrollments"
        f"?teller_enrollment_id=eq.{enrollment_id_teller}&select=id",
        headers=SUPABASE_HEADERS,
    )
    enr_resp.raise_for_status()
    enrollment_uuid = enr_resp.json()[0]["id"]
 
    # ── 3. Upsert accounts + fetch balances ───────────────────────────────────
    print("\nUpserting accounts and fetching balances...")
    account_rows = []
    for acct in accounts_raw:
        # Fetch live balances (sandbox returns them immediately)
        try:
            balances = teller_get(f"/accounts/{acct['id']}/balances")
            ledger_balance    = float(balances.get("ledger",    0) or 0)
            available_balance = float(balances.get("available", 0) or 0) if balances.get("available") else None
        except Exception as e:
            print(f"  Warning: couldn't fetch balances for {acct['id']}: {e}")
            ledger_balance    = None
            available_balance = None
 
        row = {
            "enrollment_id":       enrollment_uuid,
            "user_id":             USER_ID,
            "teller_account_id":   acct["id"],
            "name":                acct.get("name"),
            "account_type":        acct.get("type"),
            "subtype":             acct.get("subtype"),
            "status":              acct.get("status", "open"),
            "currency":            acct.get("currency", "USD"),
            "last_four":           acct.get("last_four"),
            "institution_id":      acct["institution"]["id"],
            "institution_name":    acct["institution"]["name"],
            "ledger_balance":      ledger_balance,
            "available_balance":   available_balance,
            "updated_at":          now,
        }
        account_rows.append(row)
        print(f"  {acct['id']}  {acct['name']}  ({acct['type']}/{acct['subtype']})")
 
    sb_upsert("teller_accounts", account_rows)
 
    # ── 4. Fetch + upsert transactions for each account ───────────────────────
    print("\nFetching transactions...")
    all_txn_rows = []
 
    for acct in accounts_raw:
        acct_id   = acct["id"]
        acct_type = acct["type"]
 
        txns = teller_get(f"/accounts/{acct_id}/transactions")
        print(f"  {acct_id} ({acct['name']}): {len(txns)} transaction(s)")
 
        for txn in txns:
            details        = txn.get("details", {})
            counterparty   = details.get("counterparty", {}) or {}
            amount_str     = txn["amount"]
            amount_float   = float(amount_str)
            is_debit       = derive_debit(amount_str, acct_type)
 
            row = {
                "teller_account_id":     acct_id,
                "user_id":               USER_ID,
                "teller_transaction_id": txn["id"],
                "amount":                amount_float,
                "amount_abs":            abs(amount_float),
                "is_debit":              is_debit,
                "date":                  txn["date"],
                "description":           txn.get("description"),
                "teller_category":       details.get("category"),
                "counterparty_name":     counterparty.get("name"),
                "counterparty_type":     counterparty.get("type"),
                "processing_status":     details.get("processing_status"),
                "running_balance":       float(txn["running_balance"]) if txn.get("running_balance") else None,
                "transaction_type":      txn.get("type"),
                "status":                txn.get("status"),
                "category_source":       "teller",
                "needs_review":          False,
            }
            all_txn_rows.append(row)
 
    print(f"\nUpserting {len(all_txn_rows)} total transactions...")
    # Batch in chunks of 500 to stay well under Supabase's request size limits
    chunk_size = 500
    for i in range(0, len(all_txn_rows), chunk_size):
        chunk = all_txn_rows[i : i + chunk_size]
        sb_upsert("teller_transactions", chunk)
        print(f"  Upserted rows {i + 1}–{i + len(chunk)}")
 
    print("\n✓ Sync complete.")
    print(f"  Enrollment : 1")
    print(f"  Accounts   : {len(account_rows)}")
    print(f"  Transactions: {len(all_txn_rows)}")
 
 
if __name__ == "__main__":
    sync()