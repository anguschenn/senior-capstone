"""Server-side budget progress: "spent per category this month", matching the app's Budget page.

The app computes this in Dart and discards it; alerts need it after a webhook, when no app is
open. This is a line-for-line port of the rules the Budget page uses, so the two agree:

  expense  = amount > 0, except credit card payments        (AppTransaction.expenseAmount)
  bucket   = remembered rule for the transaction's rule key (category_match_rules)
             else classify_by_pfc_signals(...)             (CategoryService.classifyByPfcSignals)
  spent    = sum of amounts per bucket, matched to budget category names by normalized key

tests/data/budget_bucket_contract.json holds cases that BOTH this module's tests and
ssdemo_1/test/services/budget_bucket_contract_test.dart must pass. If you change the rules on
either side, add a case there and make both tests pass — otherwise alerts will disagree with the
numbers on screen.

Not reproduced: category picks a user has made in the current app session but not yet
confirmed. Those live only in app memory until confirmed into category_match_rules.
"""

import re

from supabase_repo import supabase

_PAGE_SIZE = 1000


# ── Normalization (formatters.dart / CategoryService._norm) ─────────────


def normalize_category_key(raw: str) -> str:
    return re.sub(r"\s+", " ", raw.strip().lower())


def _norm(raw: str) -> str:
    value = re.sub(r"[_\s]+", " ", raw.strip().lower())
    return re.sub(r"\s+", " ", value)


def _norm_token(raw: str) -> str:
    value = _norm(raw)
    return value if value else "_"


def _coalesce(*values) -> str:
    """Dart's `a ?? b ?? ''`: first non-null value (an empty string still wins)."""
    for value in values:
        if value is not None:
            return str(value)
    return ""


# ── Rule keys (CategoryService.buildRuleKey / ruleKeyForRawTransaction) ─


def rule_key_for_row(row: dict) -> str:
    merchant_name = _coalesce(row.get("name"), row.get("merchant_name")).strip()
    pfc_primary = _coalesce(row.get("pfc_primary")).strip()
    pfc_detailed = _coalesce(row.get("pfc_detailed"), row.get("category")).strip()
    return f"{_norm_token(merchant_name)}|{_norm_token(pfc_primary)}|{_norm_token(pfc_detailed)}"


# ── PFC -> bucket (app_helpers.dart budgetCategoryFromPfc) ──────────────


def budget_category_from_pfc(pfc_detailed: str, pfc_primary: str) -> str:
    key = f"{pfc_detailed.lower()} {pfc_primary.lower()}"
    is_card_payment = "card_payment" in key or "card payment" in key

    def has(*needles):
        return any(n in key for n in needles)

    if has("atm", "withdrawal", "cash"):
        return "Cash / ATM"
    if has("utility", "utilities", "water", "electric", "gas bill", "phone", "internet"):
        return "Bills & Utilities"
    if has("rent", "mortgage", "housing", "property"):
        return "Housing"
    if has("health", "medical", "pharmacy", "clinic", "doctor", "dental"):
        return "Health"
    if has("software", "subscription", "streaming", "saas", "cloud"):
        return "Subscriptions"
    if has("food", "drink", "restaurant"):
        return "Food"
    if has("transportation", "transport", "transit"):
        return "Transport"
    if has("travel", "hotel", "gas"):
        return "Transport"
    if has("entertainment", "music", "movie", "game"):
        return "Entertainment"
    if has("grocery", "groceries"):
        return "Food"
    if has("shopping", "retail", "merchandise", "electronics"):
        return "Shopping"
    if (
        has(
            "transfer",
            "wire",
            "ach",
            "bill_payment",
            "bill payment",
            "fee",
            "insufficient funds",
            "overdraft",
        )
        or ("payment" in key and not is_card_payment)
        or ("charge" in key and not is_card_payment)
    ):
        return "Fees & Transfers"
    if has("airline", "flight"):
        return "Transport"
    return "Other"


# ── Classification (CategoryService.classifyByPfcSignals) ───────────────


def _keyword_fallback_category(merchant_name: str, transaction_name: str) -> str:
    text = f"{merchant_name.strip()} {transaction_name.strip()}".lower()
    if any(
        n in text
        for n in ("openai", "chatgpt", "spotify", "netflix", "apple.com/bill", "youtube premium")
    ):
        return "Subscriptions"
    if any(n in text for n in ("starbucks", "mcdonald", "doordash", "ubereats")):
        return "Food"
    if any(
        n in text
        for n in (
            "paypal transfer",
            "zelle payment",
            "venmo",
            "payment to chase card",
            "transfer ppd",
            "cash deposit",
        )
    ):
        return "Fees & Transfers"
    return ""


def _strong_signal_override(pfc_primary, pfc_detailed, merchant_name, transaction_name):
    primary = pfc_primary.lower()
    detailed = pfc_detailed.lower()
    text = f"{merchant_name.strip()} {transaction_name.strip()}".lower()
    if any(
        n in detailed
        for n in (
            "loan_payments_credit_card_payment",
            "transfer_out_account_transfer",
            "transfer_in_deposit",
            "bank_fees",
        )
    ):
        return ("Fees & Transfers", "high")
    if any(n in primary for n in ("loan_payments", "transfer_out", "transfer_in", "bank_fees")):
        return ("Fees & Transfers", "high")
    if any(
        n in text for n in ("payment to chase card", "paypal transfer", "zelle payment", "venmo")
    ):
        return ("Fees & Transfers", "high")
    if any(n in text for n in ("openai", "chatgpt", "spotify", "netflix")):
        return ("Subscriptions", "high")
    return None


def classify_by_pfc_signals(
    pfc_primary: str, pfc_detailed: str, merchant_name: str = "", transaction_name: str = ""
) -> tuple[str, str]:
    """Returns (category, confidence) with confidence in high | mid | low."""
    strong = _strong_signal_override(pfc_primary, pfc_detailed, merchant_name, transaction_name)
    if strong:
        return strong

    primary_category = budget_category_from_pfc("", pfc_primary)
    detailed_category = budget_category_from_pfc(pfc_detailed, "")
    keyword_category = _keyword_fallback_category(merchant_name, transaction_name)

    hits = []
    if pfc_primary.strip() and primary_category != "Other":
        hits.append(primary_category)
    if pfc_detailed.strip() and detailed_category != "Other":
        hits.append(detailed_category)
    if keyword_category:
        hits.append(keyword_category)

    if not hits:
        return ("Other", "low")
    if len(hits) == 1 or len({normalize_category_key(h) for h in hits}) > 1:
        return (hits[0], "low")
    return (hits[-1], "high" if len(hits) >= 3 else "mid")


# ── Per-transaction decisions (SyncService.buildResult loop) ────


def is_expense_row(row: dict) -> bool:
    try:
        amount = float(row.get("amount") or 0)
    except (TypeError, ValueError):
        return False
    return amount > 0


def is_credit_card_payment_row(row: dict) -> bool:
    """Checking -> card payment. The purchases already count on the card; counting this too
    would double-count. Plaid labels it LOAN_PAYMENTS_CREDIT_CARD_PAYMENT; the card side is a
    negative amount and never an expense anyway."""
    key = f"{_coalesce(row.get('pfc_detailed'), row.get('category'))} {_coalesce(row.get('pfc_primary'))}"
    return "CREDIT_CARD_PAYMENT" in key.upper()


def counts_as_spending(row: dict) -> bool:
    return is_expense_row(row) and not is_credit_card_payment_row(row)


def budget_bucket_for_row(row: dict, remembered_rules: dict[str, str]) -> str:
    remembered = remembered_rules.get(rule_key_for_row(row), "")
    if remembered:
        return remembered
    category, _ = classify_by_pfc_signals(
        pfc_primary=_coalesce(row.get("pfc_primary")).strip(),
        pfc_detailed=_coalesce(row.get("pfc_detailed"), row.get("category")).strip(),
        merchant_name=_coalesce(row.get("name"), row.get("merchant_name")).strip(),
        transaction_name=_coalesce(row.get("name")).strip(),
    )
    return category


# ── Progress (BudgetService.rebasedProgressFromTemplate, month view) ────


def build_budget_progress(
    budget_rows: list[dict],
    category_names_by_id: dict[str, str],
    tx_rows: list[dict],
    remembered_rules: dict[str, str],
    month: str,
) -> list[dict]:
    """month is 'YYYY-MM'. Output items match what PredictService's burn-rate check reads."""
    spent_by_key: dict[str, float] = {}
    for row in tx_rows:
        if not str(row.get("date") or "").startswith(month):
            continue
        if not counts_as_spending(row):
            continue
        key = normalize_category_key(budget_bucket_for_row(row, remembered_rules))
        spent_by_key[key] = spent_by_key.get(key, 0.0) + abs(float(row["amount"]))

    progress = []
    for row in budget_rows:
        budget_id = str(row.get("id") or "").strip()
        category_id = str(row.get("category_id") or "").strip()
        if not budget_id or not category_id:
            continue
        title = category_names_by_id.get(category_id, "Unknown")
        limit = float(row.get("monthly_limit") or 0)
        spent = spent_by_key.get(normalize_category_key(title), 0.0)
        progress.append(
            {
                "budget_id": budget_id,
                "category_id": category_id,
                "category": title,
                "spent": round(spent, 2),
                "limit": round(limit, 2),
                "ratio": round(spent / limit, 4) if limit > 0 else 0.0,
            }
        )
    return progress


# ── Database access ─────────────────────────────────────────────────────


def _next_month_start(month: str) -> str:
    year, mon = (int(part) for part in month.split("-"))
    return f"{year + 1}-01-01" if mon == 12 else f"{year}-{mon + 1:02d}-01"


def _fetch_month_transactions(user_id: str, month: str) -> list[dict]:
    rows: list[dict] = []
    start = 0
    while True:
        page = (
            supabase.table("transactions")
            .select(
                "plaid_transaction_id,amount,date,name,merchant_name,category,pfc_primary,pfc_detailed"
            )
            .eq("user_id", user_id)
            .gte("date", f"{month}-01")
            .lt("date", _next_month_start(month))
            .order("date")
            .range(start, start + _PAGE_SIZE - 1)
            .execute()
        ).data or []
        rows.extend(page)
        if len(page) < _PAGE_SIZE:
            return rows
        start += _PAGE_SIZE


def compute_budget_progress(user_id: str, month: str) -> list[dict]:
    """Budget progress for one user and month ('YYYY-MM'), read from the database."""
    budget_rows = (
        supabase.table("budgets")
        .select("id,category_id,monthly_limit")
        .eq("user_id", user_id)
        .eq("month_year", month)
        .execute()
    ).data or []
    if not budget_rows:
        return []
    categories = (
        supabase.table("categories")
        .select("id,name")
        .or_(f"user_id.eq.{user_id},user_id.is.null")
        .execute()
    ).data or []
    rules = (
        supabase.table("category_match_rules")
        .select("rule_key,category")
        .eq("user_id", user_id)
        .execute()
    ).data or []
    return build_budget_progress(
        budget_rows=budget_rows,
        category_names_by_id={str(c["id"]): str(c.get("name") or "") for c in categories},
        tx_rows=_fetch_month_transactions(user_id, month),
        remembered_rules={
            str(r.get("rule_key") or "").strip(): str(r.get("category") or "").strip()
            for r in rules
        },
        month=month,
    )
