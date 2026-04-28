"""Teller API integration and database sync helpers."""

import datetime as dt
from typing import Any

import httpx

from config import (
    DEMO_BANK_CONNECTION_ID,
    DEMO_USER_ID,
    TELLER_API_BASE,
    TELLER_CERT_PATH,
    TELLER_KEY_PATH,
)
from supabase_repo import supabase

ENROLLMENTS_TABLE = "teller_enrollments"
ACCOUNTS_TABLE = "teller_accounts"
TRANSACTIONS_TABLE = "teller_transactions"


class IdentityStateError(RuntimeError):
    DEMO_IDENTITY_MISSING = "demo_identity_missing"
    STORED_CONNECTION_NOT_FOUND = "stored_connection_not_found"
    STORED_ACCESS_TOKEN_MISSING = "stored_access_token_missing"

    def __init__(self, reason: str, message: str):
        super().__init__(message)
        self.reason = reason


class TellerApiError(RuntimeError):
    def __init__(self, status_code: int, code: str, message: str, body: Any = None):
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.body = body


def require_demo_identity() -> tuple[str, str | None]:
    if not DEMO_USER_ID:
        raise IdentityStateError(
            IdentityStateError.DEMO_IDENTITY_MISSING,
            "Missing DEMO_USER_ID. Set it in python/.env.",
        )
    return DEMO_USER_ID, DEMO_BANK_CONNECTION_ID


def get_stored_connection_credentials(
    user_id: str | None = None,
    connection_id: str | None = None,
) -> tuple[str, dict]:
    if not user_id:
        user_id, fallback_connection_id = require_demo_identity()
        if not connection_id:
            connection_id = fallback_connection_id
    record = _load_stored_connection(user_id, connection_id)
    access_token = record.get("access_token")
    if not access_token:
        raise IdentityStateError(
            IdentityStateError.STORED_ACCESS_TOKEN_MISSING,
            "Stored Teller access token is missing",
        )
    return access_token, record


def _load_stored_connection(user_id: str, connection_id: str | None) -> dict:
    if connection_id:
        row = (
            supabase.table(ENROLLMENTS_TABLE)
            .select("*")
            .eq("id", connection_id)
            .eq("user_id", user_id)
            .limit(1)
            .execute()
        )
        if row.data:
            return row.data[0]

    row = (
        supabase.table(ENROLLMENTS_TABLE)
        .select("*")
        .eq("user_id", user_id)
        .order("created_at", desc=True)
        .limit(1)
        .execute()
    )
    if not row.data:
        raise IdentityStateError(
            IdentityStateError.STORED_CONNECTION_NOT_FOUND,
            "No stored teller_enrollments record for configured demo identity",
        )
    return row.data[0]


def store_teller_access_token(
    *,
    user_id: str,
    connection_id: str | None,
    access_token: str,
    enrollment_id: str | None = None,
    institution: dict | None = None,
) -> None:
    institution = institution or {}
    payload = {
        "user_id": user_id,
        "access_token": access_token,
        "teller_enrollment_id": enrollment_id,
        "institution_id": institution.get("id"),
        "institution_name": institution.get("name"),
    }
    if connection_id:
        payload["id"] = connection_id

    supabase.table(ENROLLMENTS_TABLE).upsert(
        payload,
        on_conflict="id",
    ).execute()


def sync_accounts_to_supabase(
    user_id: str,
    connection_id: str,
    access_token: str,
) -> list[dict]:
    accounts = _teller_get("/accounts", access_token)
    rows = []
    for account in accounts:
        account_id = account.get("id")
        if not account_id:
            continue
        balances = _safe_get_balances(account_id, access_token)
        rows.append(
            {
                "enrollment_id": connection_id,
                "user_id": user_id,
                "teller_account_id": account_id,
                "name": account.get("name"),
                "account_type": account.get("type"),
                "subtype": account.get("subtype"),
                "status": account.get("status"),
                "currency": account.get("currency"),
                "ledger_balance": _parse_money(balances.get("ledger")),
                "available_balance": _parse_money(balances.get("available")),
                "last_four": account.get("last_four"),
                "institution_id": (account.get("institution") or {}).get("id"),
                "institution_name": (account.get("institution") or {}).get("name"),
                "updated_at": dt.datetime.now().isoformat(),
            }
        )

    if rows:
        supabase.table(ACCOUNTS_TABLE).upsert(
            rows,
            on_conflict="teller_account_id",
        ).execute()
    return accounts


def sync_transactions_to_supabase(
    user_id: str,
    connection_id: str,
    access_token: str,
    connection: dict | None = None,
) -> dict:
    connection = connection or {}
    accounts = sync_accounts_to_supabase(user_id, connection_id, access_token)
    start_date = _sync_start_date(connection.get("last_synced_at"))
    transaction_count = 0

    for account in accounts:
        account_id = account.get("id")
        if not account_id or account.get("status") == "closed":
            continue

        account_name = account.get("name") or ""
        uses_depository_sign = _uses_checking_savings_polarity(account_name)

        for transaction in _iter_transactions(account_id, access_token, start_date):
            details = transaction.get("details") or {}
            counterparty = details.get("counterparty") or {}
            transaction_id = transaction.get("id")
            if not transaction_id:
                continue
            amount = _parse_money(transaction.get("amount")) or 0

            row = {
                "teller_account_id": account_id,
                "user_id": user_id,
                "teller_transaction_id": transaction_id,
                "amount": amount,
                "amount_abs": abs(amount),
                "is_debit": amount < 0 if uses_depository_sign else amount > 0,
                "date": transaction.get("date"),
                "description": transaction.get("description"),
                "teller_category": details.get("category"),
                "counterparty_name": counterparty.get("name"),
                "counterparty_type": counterparty.get("type"),
                "transaction_type": transaction.get("type"),
                "processing_status": details.get("processing_status"),
                "running_balance": _parse_money(transaction.get("running_balance")),
                "status": transaction.get("status"),
                "category_source": "teller" if details.get("category") else None,
                "needs_review": details.get("processing_status") != "complete",
            }
            supabase.table(TRANSACTIONS_TABLE).upsert(
                row,
                on_conflict="teller_transaction_id",
            ).execute()
            transaction_count += 1

    supabase.table(ENROLLMENTS_TABLE).update(
        {"last_synced_at": dt.datetime.now().isoformat()}
    ).eq("id", connection_id).eq("user_id", user_id).execute()

    return {
        "accounts": len(accounts),
        "transactions": transaction_count,
        "provider": "teller",
    }


def format_error(error: TellerApiError) -> dict:
    return {
        "error": {
            "status_code": error.status_code,
            "display_message": str(error),
            "error_code": error.code,
            "error_type": "TELLER_API_ERROR",
        }
    }


def _iter_transactions(account_id: str, access_token: str, start_date: str | None):
    count = 500
    from_id = None
    while True:
        params: dict[str, str | int] = {"count": count}
        if start_date:
            params["start_date"] = start_date
        if from_id:
            params["from_id"] = from_id
        page = _teller_get(
            f"/accounts/{account_id}/transactions",
            access_token,
            params=params,
        )
        if not page:
            break
        for transaction in page:
            yield transaction
        if len(page) < count:
            break
        next_from_id = page[-1].get("id")
        if not next_from_id or next_from_id == from_id:
            break
        from_id = next_from_id


def _sync_start_date(last_synced_at: str | None) -> str | None:
    if not last_synced_at:
        return None
    try:
        parsed = dt.datetime.fromisoformat(last_synced_at[:19]).date()
    except Exception:
        return None
    return (parsed - dt.timedelta(days=10)).isoformat()


def _safe_get_balances(account_id: str, access_token: str) -> dict:
    try:
        balances = _teller_get(f"/accounts/{account_id}/balances", access_token)
        return balances if isinstance(balances, dict) else {}
    except TellerApiError as error:
        if error.status_code in (404, 410):
            return {}
        raise


def _teller_get(path: str, access_token: str, params: dict | None = None):
    url = TELLER_API_BASE.rstrip("/") + path
    try:
        cert = _client_cert()
        client_kwargs = {"timeout": 30}
        if cert:
            client_kwargs["cert"] = cert
        with httpx.Client(**client_kwargs) as client:
            response = client.get(
                url,
                params=params,
                auth=(access_token, ""),
            )
    except httpx.RequestError as error:
        raise TellerApiError(
            502,
            "teller_network_error",
            f"Failed to reach Teller API: {error}",
        ) from error

    if response.status_code >= 400:
        body = _safe_json(response)
        code = body.get("code") or body.get("error") or "teller_api_error"
        message = body.get("message") or response.text or "Teller API request failed"
        raise TellerApiError(response.status_code, code, message, body)

    return response.json()


def _client_cert():
    if TELLER_CERT_PATH and TELLER_KEY_PATH:
        return (TELLER_CERT_PATH, TELLER_KEY_PATH)
    return None


def _safe_json(response: httpx.Response) -> dict:
    try:
        parsed = response.json()
        return parsed if isinstance(parsed, dict) else {}
    except Exception:
        return {}


def _parse_money(value):
    if value is None:
        return None


def _uses_checking_savings_polarity(account_name: str) -> bool:
    key = (account_name or "").lower()
    return "checking" in key or "saving" in key
    if isinstance(value, (int, float)):
        return value
    try:
        return float(str(value))
    except Exception:
        return None
