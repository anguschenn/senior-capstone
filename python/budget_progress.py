"""Server-side budget progress: "spent per category this month", matching the app's Budget page.

The app computes this in Dart and discards it; alerts need it after a webhook, when no app is
open. This is a line-for-line port of the rules the Budget page uses, so the two agree:

  kind     = spend | refund | income | internal              (AppTransaction.ownKind)
             card payments and transfers between own accounts don't count; a refund
             nets against the bucket of the purchase it pays back
  expense  = amount for spend, minus amount for a refund      (AppTransaction.expenseAmount)
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

import datetime as dt
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
    return row_kind(row) == "spend"


# ── What counts (AppTransaction.ownKind / classifyTransactions) ─────────

INTERNAL_TRANSFER = "Internal Transfer"

_PEER_TO_PEER = ("zelle", "venmo", "paypal", "cash app", "apple cash")
_SPENDING_PFC = {
    "FOOD_AND_DRINK",
    "GENERAL_MERCHANDISE",
    "GENERAL_SERVICES",
    "ENTERTAINMENT",
    "TRAVEL",
    "TRANSPORTATION",
    "PERSONAL_CARE",
    "HOME_IMPROVEMENT",
    "MEDICAL",
    "RENT_AND_UTILITIES",
    "BANK_FEES",
}


def is_peer_to_peer(text: str) -> bool:
    lowered = text.lower()
    return any(n in lowered for n in _PEER_TO_PEER)


def _row_fields(row: dict) -> tuple[str, str, str, str]:
    """(name, description, pfc_primary, pfc_detailed) as AppTransaction.fromMap reads them."""
    name_raw = row.get("name")
    merchant = (_coalesce(row.get("merchant_name")) or "").strip()
    description = (_coalesce(name_raw)).strip()
    if description:
        name = description
    elif merchant:
        name = merchant
    else:
        name = "Unknown"
    detailed = _coalesce(row.get("pfc_detailed"), row.get("category")).strip()
    primary = _coalesce(row.get("pfc_primary")).strip()
    return name, description, primary, detailed


def _is_refund_like(text: str, primary: str, detailed: str) -> bool:
    lowered = f"{text} {primary} {detailed}".lower().replace("_", " ")
    return any(n in lowered for n in ("refund", "reversal", "returned", "return"))


def kind_of(
    amount: float,
    name: str,
    description: str,
    pfc_primary: str,
    pfc_detailed: str,
    account_type: str = "",
    user_category: str = "",
) -> str:
    """spend | refund | income | internal | none. user_category is a remembered rule:
    Internal Transfer stops it counting, any other pick (except the old Fees & Transfers
    catch-all) counts it, money in as income or a refund of that category."""
    if amount == 0:
        return "none"
    if user_category == INTERNAL_TRANSFER:
        return "internal"
    if user_category and user_category != "Fees & Transfers":
        if amount > 0:
            return "spend"
        return "income" if user_category == "Income" else "refund"
    if amount > 0:
        return "spend"
    text = f"{name.lower()} {description.lower()}"
    if _is_refund_like(text, pfc_primary, pfc_detailed) or (
        pfc_primary.upper().strip() in _SPENDING_PFC
    ):
        return "refund"
    return "income"


def row_kind(row: dict, user_category: str = "", account_type: str = "") -> str:
    try:
        amount = float(row.get("amount") or 0)
    except (TypeError, ValueError):
        return "none"
    name, description, primary, detailed = _row_fields(row)
    return kind_of(amount, name, description, primary, detailed, account_type, user_category)


def merchant_match_key(name: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^a-z ]", " ", name.lower())).strip()


def row_id(row: dict) -> str:
    provider = _coalesce(row.get("plaid_transaction_id")).strip()
    if provider:
        return provider
    name = _row_fields(row)[0]
    try:
        amount = float(row.get("amount") or 0)
    except (TypeError, ValueError):
        amount = 0.0
    return f"{name.lower()}|{amount:.2f}|{str(row.get('date') or '')[:10]}"


def classify_rows(
    tx_rows: list[dict],
    remembered_rules: dict[str, str],
    account_type_by_id: dict[str, str] | None = None,
) -> dict[str, tuple[str, str]]:
    """{row id: (kind, bucket)} (classifyTransactions). A refund from a merchant with an
    earlier purchase of at least that amount on the same account, within 120 days, takes
    that purchase's bucket."""

    account_type_by_id = account_type_by_id or {}
    parsed = []
    for row in tx_rows:
        user_category = remembered_rules.get(rule_key_for_row(row), "")
        account_id = _coalesce(row.get("plaid_account_id")).strip()
        kind = row_kind(row, user_category, account_type_by_id.get(account_id, ""))
        try:
            day = dt.date.fromisoformat(str(row.get("date") or "")[:10])
        except ValueError:
            day = None
        name, description, primary, detailed = _row_fields(row)
        try:
            signed = float(row.get("amount") or 0)
        except (TypeError, ValueError):
            signed = 0.0
        amount = abs(signed)
        parsed.append(
            {
                "transfer_like": looks_like_transfer(name, description, primary, detailed),
                "signed": signed,
                "id": row_id(row),
                "kind": kind,
                "bucket": budget_bucket_for_row(row, remembered_rules),
                "user_category": user_category,
                "account": account_id,
                "day": day,
                "amount": amount,
                "key": merchant_match_key(name),
                "p2p": is_peer_to_peer(f"{name} {description}"),
            }
        )
    _pair_own_transfers(parsed)
    purchases: dict[str, list[dict]] = {}
    for item in parsed:
        if item["kind"] == "spend":
            purchases.setdefault(item["key"], []).append(item)
    out = {}
    for item in parsed:
        kind, bucket = item["kind"], item["bucket"]
        if (
            kind in ("income", "refund")
            and item["key"]
            and not item["p2p"]
            and item["day"] is not None
            and (not item["user_category"] or item["user_category"] == "Fees & Transfers")
        ):
            match = _matching_purchase(item, purchases.get(item["key"], []))
            if match is not None:
                kind, bucket = "refund", match["bucket"]
        if kind == "internal" and not item["user_category"]:
            bucket = INTERNAL_TRANSFER
        out[item["id"]] = (kind, bucket)
    return out


def looks_like_transfer(name: str, description: str, pfc_primary: str, pfc_detailed: str) -> bool:
    """A row a bank would use for moving money (looksLikeTransfer)."""
    pfc = f"{pfc_primary} {pfc_detailed}".upper()
    if "TRANSFER" in pfc or "LOAN_" in pfc:
        return True
    return (
        re.search(
            r"\b(transfer|trans|xfer|trnsfr|payment|deposit|withdrawal|online)\b",
            f"{name} {description}".lower(),
        )
        is not None
    )


def _pair_own_transfers(parsed: list[dict]) -> None:
    """Money leaving one linked account and the same amount arriving in another within 5
    days is a move between own accounts (_pairOwnTransfers). Money to or from an account the
    app doesn't have counts as spending or income."""

    def candidate(item: dict) -> bool:
        if not item["account"] or item["day"] is None:
            return False
        if item["user_category"] and item["user_category"] != "Fees & Transfers":
            return False
        return item["kind"] in ("spend", "income") and not item["p2p"] and item["transfer_like"]

    # Oldest first, each taking the closest-dated match, so the app and the server pair
    # the same rows whatever order they arrive in.
    def by_date_then_id(item: dict):
        return (item["day"], item["id"])

    outflows = sorted((i for i in parsed if i["signed"] > 0 and candidate(i)), key=by_date_then_id)
    inflows = sorted((i for i in parsed if i["signed"] < 0 and candidate(i)), key=by_date_then_id)
    paired: set[str] = set()
    for out in outflows:
        best, best_gap = None, 0
        for into in inflows:
            if into["id"] in paired or into["account"] == out["account"]:
                continue
            if abs(into["amount"] - out["amount"]) >= 0.005:
                continue
            gap = abs((into["day"] - out["day"]).days)
            if gap > 5:
                continue
            if best is None or gap < best_gap:
                best, best_gap = into, gap
        if best is None:
            continue
        paired.update((out["id"], best["id"]))
        out["kind"] = best["kind"] = "internal"


def _matching_purchase(refund: dict, purchases: list[dict]) -> dict | None:
    best = None
    for purchase in purchases:
        if refund["account"] and purchase["account"] and refund["account"] != purchase["account"]:
            continue
        if purchase["day"] is None:
            continue
        days = (refund["day"] - purchase["day"]).days
        if days < 0 or days > 120:
            continue
        if purchase["amount"] + 0.005 < refund["amount"]:
            continue
        exact = abs(purchase["amount"] - refund["amount"]) < 0.005
        if best is None:
            best = purchase
            continue
        best_exact = abs(best["amount"] - refund["amount"]) < 0.005
        if (exact and not best_exact) or (exact == best_exact and purchase["day"] > best["day"]):
            best = purchase
    return best


def signed_spend(kind: str, amount: float) -> float:
    """AppTransaction.expenseAmount: spending positive, a refund negative, else 0."""
    if kind == "spend":
        return abs(amount)
    if kind == "refund":
        return -abs(amount)
    return 0.0


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
    *,
    kinds: dict[str, tuple[str, str]] | None = None,
) -> list[dict]:
    """month is 'YYYY-MM'. Output items match what PredictService's burn-rate check reads.
    kinds is classify_rows(tx_rows, remembered_rules) when the caller already has it."""
    spent_by_key: dict[str, float] = {}
    if kinds is None:
        kinds = classify_rows(tx_rows, remembered_rules)
    counted: set[str] = set()
    for row in tx_rows:
        if not str(row.get("date") or "").startswith(month):
            continue
        # A transaction stored twice counts once, as the app de-duplicates on sync.
        rid = row_id(row)
        if rid in counted:
            continue
        counted.add(rid)
        kind, bucket = kinds[rid]
        amount = signed_spend(kind, float(row["amount"]))
        if amount == 0:
            continue
        key = normalize_category_key(bucket)
        spent_by_key[key] = spent_by_key.get(key, 0.0) + amount

    # A bucket with no budget row of its own counts toward "Other" when there is one, so the
    # cards add up to the month's expenses (BudgetService.cardKeyForBucket).
    card_keys = {
        normalize_category_key(
            category_names_by_id.get(str(row.get("category_id") or "").strip(), "Unknown")
        )
        for row in budget_rows
    }
    other_key = normalize_category_key("Other")
    spent_by_card: dict[str, float] = {}
    for key, amount in spent_by_key.items():
        if key not in card_keys and other_key in card_keys:
            key = other_key
        spent_by_card[key] = spent_by_card.get(key, 0.0) + amount

    progress = []
    for row in budget_rows:
        budget_id = str(row.get("id") or "").strip()
        category_id = str(row.get("category_id") or "").strip()
        if not budget_id or not category_id:
            continue
        title = category_names_by_id.get(category_id, "Unknown")
        limit = float(row.get("monthly_limit") or 0)
        spent = spent_by_card.get(normalize_category_key(title), 0.0)
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


REFUND_LOOKBACK_MONTHS = 4  # earlier purchases a refund in `month` can match
PAIR_LOOKAHEAD_DAYS = 5  # a move on the 31st can arrive in the other account days later


def _months_before(month: str, count: int) -> str:
    year, mon = (int(part) for part in month.split("-"))
    index = year * 12 + (mon - 1) - count
    return f"{index // 12}-{index % 12 + 1:02d}"


def fetch_hidden_account_ids(user_id: str, db=None) -> set[str]:
    """Accounts the user hid in the app (accounts.hidden): treated as never linked. Empty
    when the column isn't there yet (db/migrations/016_accounts_hidden.sql not applied)."""
    try:
        rows = (
            (db or supabase)
            .table("accounts")
            .select("plaid_account_id")
            .eq("user_id", user_id)
            .eq("hidden", True)
            .execute()
        ).data or []
    except Exception:
        return set()
    return {str(r.get("plaid_account_id") or "").strip() for r in rows} - {""}


def without_hidden_accounts(rows: list[dict], hidden: set[str]) -> list[dict]:
    if not hidden:
        return rows
    return [r for r in rows if str(r.get("plaid_account_id") or "").strip() not in hidden]


def _fetch_month_transactions(user_id: str, month: str) -> list[dict]:
    """The month's transactions plus the few months before, for refund matching, and the
    first days after, so a move between own accounts at month end still pairs."""
    end = dt.date.fromisoformat(_next_month_start(month)) + dt.timedelta(days=PAIR_LOOKAHEAD_DAYS)
    rows: list[dict] = []
    start = 0
    while True:
        page = (
            supabase.table("transactions")
            .select(
                "plaid_transaction_id,plaid_account_id,amount,date,name,merchant_name,category,"
                "pfc_primary,pfc_detailed"
            )
            .eq("user_id", user_id)
            .gte("date", f"{_months_before(month, REFUND_LOOKBACK_MONTHS)}-01")
            .lt("date", end.isoformat())
            .order("date")
            .range(start, start + _PAGE_SIZE - 1)
            .execute()
        ).data or []
        rows.extend(page)
        if len(page) < _PAGE_SIZE:
            return without_hidden_accounts(rows, fetch_hidden_account_ids(user_id))
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
