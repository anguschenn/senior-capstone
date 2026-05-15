"""V2 deterministic executors for canonical execution plans."""

import re


def execute_plan_v2(plan, query_spec, summary, scope_label):
    if plan is None or query_spec is None or not isinstance(summary, dict):
        return None
    if plan.operation == "spending_change_month_over_month":
        return _exec_spending_change(query_spec, summary, scope_label)
    if plan.operation == "amount_month_lookup":
        return _exec_amount_month(query_spec, summary, scope_label)
    if plan.operation == "compare_periods":
        return _exec_compare_periods(query_spec, summary, scope_label)
    if plan.operation == "top_category_lookup":
        return _exec_top_category(query_spec, summary, scope_label)
    if plan.operation == "recent_transactions":
        return _exec_recent_transactions(summary, scope_label)
    return None


def _prev_month_key(month_key):
    if not re.match(r"^20\d{2}-\d{2}$", month_key or ""):
        return ""
    year_s, month_s = month_key.split("-")
    year = int(year_s)
    month = int(month_s)
    if month == 1:
        return f"{year - 1}-12"
    return f"{year}-{month - 1:02d}"


def _exec_spending_change(query_spec, summary, scope_label):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    target = query_spec.period_key
    if not target:
        return None
    prev = _prev_month_key(target)
    if not prev:
        return None
    target_row = month_index.get(target)
    prev_row = month_index.get(prev)
    if not isinstance(target_row, dict) or not isinstance(prev_row, dict):
        return None

    target_exp = float(target_row.get("expenses", 0) or 0)
    prev_exp = float(prev_row.get("expenses", 0) or 0)
    delta = target_exp - prev_exp
    if abs(delta) < 1:
        reply = (
            f"Your spending in {target} was roughly flat versus {prev} "
            f"for {scope_label} (${target_exp:.0f} vs ${prev_exp:.0f})."
        )
    else:
        direction = "increased" if delta > 0 else "decreased"
        reply = (
            f"Your spending in {target} {direction} versus {prev} "
            f"for {scope_label} by about ${abs(delta):.0f} "
            f"(${target_exp:.0f} vs ${prev_exp:.0f})."
        )

    top = target_row.get("top_category") if isinstance(target_row.get("top_category"), dict) else {}
    top_name = str(top.get("name", "") or "").strip()
    top_amt = float(top.get("amount", 0) or 0)
    if top_name and top_amt > 0:
        reply = (
            f"{reply} The largest non-transfer category in {target} was "
            f"{top_name} at about ${top_amt:.0f}."
        )
    return {
        "reply": reply,
        "insights": [
            "This compares the target month versus the prior month using validated month indexes."
        ],
        "actions": ["Ask for a category-by-category delta if you want a deeper breakdown."],
        "missing_fields": [],
        "facts_used": ["month_index.expenses", "month_index.top_category"],
        "period_resolved": f"{target} vs {prev}",
    }


def _exec_amount_month(query_spec, summary, scope_label):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    target = query_spec.period_key
    if not target:
        return None
    row = month_index.get(target)
    if not isinstance(row, dict):
        return None
    metric = query_spec.metric if query_spec.metric in {"income", "expenses"} else "expenses"
    amount = float(row.get(metric, 0) or 0)
    if metric == "expenses":
        top = row.get("top_category") if isinstance(row.get("top_category"), dict) else {}
        top_name = str(top.get("name", "") or "").strip()
        top_amt = float(top.get("amount", 0) or 0)
        if top_name and top_amt > 0:
            reply = (
                f"For {target}, total expenses for {scope_label} are about ${amount:.0f}; "
                f"top category is {top_name} at about ${top_amt:.0f}."
            )
        else:
            reply = f"For {target}, total expenses for {scope_label} are about ${amount:.0f}."
    else:
        reply = f"For {target}, total income for {scope_label} are about ${amount:.0f}."

    return {
        "reply": reply,
        "insights": ["Amount derived directly from validated summary indexes."],
        "actions": ["Ask a follow-up for category or day-level breakdown if needed."],
        "missing_fields": [],
        "facts_used": [f"month_index.{metric}"],
        "period_resolved": target,
    }


def _lookup_period_expense(period, summary):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    year_index = summary.get("year_index") if isinstance(summary.get("year_index"), dict) else {}
    if re.match(r"^20\d{2}-\d{2}$", period):
        row = month_index.get(period)
        if isinstance(row, dict):
            return float(row.get("expenses", 0) or 0), "month"
        return None, "month"
    if re.match(r"^20\d{2}$", period):
        row = year_index.get(period)
        if isinstance(row, dict):
            return float(row.get("expenses", 0) or 0), "year"
        annual = (
            summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
        )
        annual_year = str(int(annual.get("year", 0) or 0))
        if annual_year == period:
            totals = annual.get("totals") if isinstance(annual.get("totals"), dict) else {}
            return float(totals.get("expenses_year", 0) or 0), "year"
        return None, "year"
    return None, "unknown"


def _exec_compare_periods(query_spec, summary, scope_label):
    period_key = query_spec.period_key or ""
    parts = [x.strip() for x in period_key.split(",") if x.strip()]
    if len(parts) < 2:
        return None
    left, right = parts[0], parts[1]
    left_amount, left_kind = _lookup_period_expense(left, summary)
    right_amount, right_kind = _lookup_period_expense(right, summary)
    if left_amount is None or right_amount is None or left_kind != right_kind:
        return None
    diff = right_amount - left_amount
    pct = 0.0 if left_amount == 0 else (diff / left_amount) * 100.0
    return {
        "reply": (
            f"Comparing {left} vs {right} for {scope_label}: "
            f"${left_amount:.0f} vs ${right_amount:.0f}, change ${diff:.0f} ({pct:.1f}%)."
        ),
        "insights": ["Period comparison is calculated directly from validated summary indexes."],
        "actions": ["Ask a follow-up to break down the largest categories for each period."],
        "missing_fields": [],
        "facts_used": ["month_index.expenses/year_index.expenses"],
        "period_resolved": f"{left} vs {right}",
    }


def _exec_top_category(query_spec, summary, scope_label):
    period_type = query_spec.period_type
    period_key = query_spec.period_key
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    if period_type == "month" and period_key:
        row = month_index.get(period_key)
        if isinstance(row, dict):
            top = row.get("top_category") if isinstance(row.get("top_category"), dict) else {}
            name = str(top.get("name", "") or "").strip()
            amount = float(top.get("amount", 0) or 0)
            if name and amount > 0:
                return {
                    "reply": (
                        f"For {period_key}, the top category for {scope_label} "
                        f"is {name} at about ${amount:.0f}."
                    ),
                    "insights": [
                        "Top-category answer is read directly from validated summary indexes."
                    ],
                    "actions": [
                        "Ask a follow-up for day-level transactions in that category if needed."
                    ],
                    "missing_fields": [],
                    "facts_used": ["month_index.top_category"],
                    "period_resolved": period_key,
                }
    annual = (
        summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
    )
    annual_cats = (
        annual.get("top_expense_categories_year")
        if isinstance(annual.get("top_expense_categories_year"), list)
        else []
    )
    if annual_cats and isinstance(annual_cats[0], dict):
        top = annual_cats[0]
        name = str(top.get("category", "") or "").strip()
        amount = float(top.get("amount", 0) or 0)
        if name and amount > 0:
            return {
                "reply": f"In the yearly summary for {scope_label}, the top category is {name} at about ${amount:.0f}.",
                "insights": [
                    "Top-category answer is read directly from validated summary indexes."
                ],
                "actions": [
                    "Ask a follow-up for day-level transactions in that category if needed."
                ],
                "missing_fields": [],
                "facts_used": ["annual_summary.top_expense_categories_year"],
                "period_resolved": "year",
            }
    rolling = (
        summary.get("top_expense_categories")
        if isinstance(summary.get("top_expense_categories"), list)
        else []
    )
    if rolling and isinstance(rolling[0], dict):
        top = rolling[0]
        name = str(top.get("category", "") or "").strip()
        amount = float(top.get("amount", 0) or 0)
        if name and amount > 0:
            return {
                "reply": f"In the last 30 days for {scope_label}, the top category is {name} at about ${amount:.0f}.",
                "insights": [
                    "Top-category answer is read directly from validated summary indexes."
                ],
                "actions": [
                    "Ask a follow-up for day-level transactions in that category if needed."
                ],
                "missing_fields": [],
                "facts_used": ["top_expense_categories"],
                "period_resolved": "rolling_30d",
            }
    return None


def _exec_recent_transactions(summary, scope_label):
    recent = (
        summary.get("recent_transactions")
        if isinstance(summary.get("recent_transactions"), list)
        else []
    )
    if not recent:
        return None
    rows = []
    for item in recent[:5]:
        if not isinstance(item, dict):
            continue
        d = str(item.get("date", "") or "").strip()
        n = str(item.get("name", "") or "Transaction").strip()
        a = float(item.get("amount", 0) or 0)
        if not d:
            continue
        sign = "-" if a < 0 else "+"
        rows.append(f"{d} {n} {sign}${abs(a):.0f}")
    if not rows:
        return None
    return {
        "reply": f"Most recent transactions for {scope_label}: {'; '.join(rows)}.",
        "insights": ["Recent transactions are read directly from validated summary rows."],
        "actions": ["Ask for a specific date range or merchant if you want a narrower slice."],
        "missing_fields": [],
        "facts_used": ["recent_transactions"],
        "period_resolved": "recent",
    }
