"""V2 deterministic executors for canonical execution plans."""

import calendar
import dataclasses
import math
import re
from datetime import date as date_cls
from datetime import timedelta

from .query_parser_v2 import category_named, credit_card_scope, group_months
from .response_utils import describe_plaid_amount


def execute_plan_v2(plan, query_spec, summary, scope_label):
    if plan is None or query_spec is None or not isinstance(summary, dict):
        return None
    if plan.operation == "spending_change_month_over_month":
        return _exec_spending_change(query_spec, summary, scope_label)
    if plan.operation == "amount_day_lookup":
        return _exec_amount_day(query_spec, summary, scope_label)
    if plan.operation == "amount_month_lookup":
        return _exec_amount_month(query_spec, summary, scope_label)
    extra_ops = {
        "category_change": _exec_category_change,
        "spending_trend": _exec_spending_trend,
        "hotspots": _exec_hotspots,
        "amount_rolling": _exec_amount_rolling,
        "amount_month_range": _exec_amount_month_range,
        "what_if_rate_math": _exec_rate_math,
        "month_extreme": _exec_month_extreme,
        "savings_goal": _exec_savings_goal,
        "year_amount": _exec_year_amount,
        "affordability": _exec_affordability,
        "budget_suggestion": _exec_budget_suggestion,
        "what_if_cap_amount": _exec_cap_amount,
        "amount_judgement": _exec_amount_judgement,
        "derived_metric": _exec_derived_metric,
        "goal_time": _exec_goal_time,
        "threshold_check": _exec_threshold_check,
        "count_months": _exec_count_months,
        "percent_of": _exec_percent_of,
        "all_time": _exec_all_time,
        "day_span": _exec_day_span,
        "saving_target": _exec_saving_target,
        "month_outlook": _exec_month_outlook,
        "extra_spend": _exec_extra_spend,
        "week_compare": _exec_week_compare,
    }
    if plan.operation in extra_ops:
        return extra_ops[plan.operation](query_spec, summary, scope_label)
    if plan.operation == "pace_check":
        return _exec_pace_check(query_spec, summary, scope_label)
    if plan.operation == "data_pointer":
        return _exec_data_pointer(query_spec, summary, scope_label)
    if plan.operation == "month_overview":
        return _exec_month_overview(query_spec, summary, scope_label)
    if plan.operation == "what_if_cut_dollars":
        return _exec_what_if_cut_dollars(query_spec, summary, scope_label)
    if plan.operation == "what_if_cut_percent":
        return _exec_what_if_cut(query_spec, summary, scope_label)
    if plan.operation == "what_if_cancel_merchant":
        return _exec_what_if_cancel(query_spec, summary, scope_label)
    if plan.operation == "category_month_lookup":
        return _exec_category_month(query_spec, summary, scope_label)
    if plan.operation == "compare_periods":
        return _exec_compare_periods(query_spec, summary, scope_label)
    if plan.operation == "top_category_lookup":
        return _exec_top_category(query_spec, summary, scope_label)
    if plan.operation == "recent_transactions":
        return _exec_recent_transactions(summary, scope_label, query_spec)
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
    # "2026-09,2026-06": why September differs from June, after comparing the two.
    target, _, baseline = (query_spec.period_key or "").partition(",")
    if not target:
        return None
    prev = baseline or _prev_month_key(target)
    if not prev:
        return None
    target_row = month_index.get(target)
    prev_row = month_index.get(prev)
    if isinstance(target_row, dict) and not isinstance(prev_row, dict) and month_index:
        if prev < min(month_index):
            return _pointer(
                f"{target} is the first month in your data, so there's no month before it to "
                f"compare with. You spent about ${float(target_row.get('expenses', 0) or 0):.0f} "
                "that month.",
                f"Ask how {target} compares with a later month.",
            )
    if not isinstance(target_row, dict) or not isinstance(prev_row, dict):
        return None
    category = (query_spec.category or "").split(",")[0].strip()
    if category and not _month_scale(target)[1]:
        # "why the jump?" after a category question explains that category.
        now = _month_amount(target_row, category) or 0.0
        before = _month_amount(prev_row, category) or 0.0
        gap = now - before
        moved = "rose" if gap > 0 else "fell"
        return _pointer(
            f"{category} spending for {scope_label} {moved} from ${before:.0f} in {prev} to "
            f"${now:.0f} in {target} ({'+' if gap >= 0 else '-'}${abs(gap):.0f}). Chat only "
            f"sees category totals, so it can't tell which purchases drove that; Activity lists "
            f"the {category} charges for {target}.",
            f"Search Activity for {category} in {target}.",
            ("month_index.categories",),
        )

    target_exp = float(target_row.get("expenses", 0) or 0)
    prev_exp = float(prev_row.get("expenses", 0) or 0)
    # A month still in progress is compared at its projected full-month total.
    factor, progress = _month_scale(target)
    target_full = target_exp * factor
    delta = target_full - prev_exp
    if progress:
        so_far = (
            f"Your spending in {target} is on pace for about ${target_full:.0f} for "
            f"{scope_label} (${target_exp:.0f} so far, {progress[0]} of {progress[1]} days)"
        )
        if abs(delta) < 1:
            reply = f"{so_far}, about the same as {prev} (${prev_exp:.0f})."
        else:
            word = "higher" if delta > 0 else "lower"
            reply = f"{so_far}, about ${abs(delta):.0f} {word} than {prev} (${prev_exp:.0f})."
    elif abs(delta) < 1:
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

    deltas = _category_deltas(prev_row, target_row, after_factor=factor)
    if deltas:
        changes = ", ".join(
            f"{name} {'+' if diff > 0 else '-'}${abs(diff):.0f}" for name, diff in deltas[:3]
        )
        label = "Biggest changes by category"
        if progress:
            label = "Biggest projected changes by category"
        reply = f"{reply} {label}: {changes}."
        unsplit = delta - sum(diff for _, diff in deltas)
        if not progress and abs(unsplit) >= 50 and abs(unsplit) > 0.5 * abs(delta):
            reply += (
                f" Transfers and payments, which aren't split by category, "
                f"{'rose' if unsplit > 0 else 'fell'} by about ${abs(unsplit):.0f}."
            )
    else:
        top = target_row.get("top_category")
        top = top if isinstance(top, dict) else {}
        top_name = str(top.get("name", "") or "").strip()
        top_amt = float(top.get("amount", 0) or 0)
        if top_name and top_amt > 0:
            reply = (
                f"{reply} The largest non-transfer category in {target} was "
                f"{top_name} at about ${top_amt:.0f}."
            )
        elif not progress and abs(delta) >= 50:
            reply += " None of it is split by category; it's transfers and payments."
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


def _income_vs_usual(summary, target):
    """ "Why is my income so low": this month's income against the months before it.
    Chat sees totals only, so it can't say which deposit changed."""
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    keys = []
    month = target
    while len(keys) < 3:
        month = _prev_month_key(month)
        if not month or month not in month_index:
            break
        keys.append(month)
    if not keys:
        return ""
    usual = sum(float(month_index[k].get("income", 0) or 0) for k in keys) / len(keys)
    span = keys[0] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
    amount = float((month_index.get(target) or {}).get("income", 0) or 0)
    lead = "So far that's" if target == date_cls.today().strftime("%Y-%m") else "That's"
    if usual <= 0:
        compare = "You had no recorded income in the months before it."
    elif amount < usual * 0.9:
        compare = f"{lead} below your usual ${usual:.0f} a month ({span})."
    elif amount > usual * 1.1:
        compare = f"{lead} above your usual ${usual:.0f} a month ({span})."
    else:
        compare = f"That's close to your usual ${usual:.0f} a month ({span})."
    return (
        f" {compare} Chat sees totals only, so it can't tell which deposit changed; Activity "
        "lists each one."
    )


def _card_payment_note(summary, rows, metric):
    """One sentence on credit card payments, which are neither income nor spending: for
    all accounts, income leaves out payments onto cards; for one bank account, spending
    leaves out its payments to a card."""
    rows = [r for r in rows if isinstance(r, dict)]
    if not rows or credit_card_scope(summary):
        return ""
    if summary.get("scope") == "single_account":
        paid = sum(float(r.get("card_payments_out", 0) or 0) for r in rows)
        if paid >= 1 and metric in {"expenses", "net", "both"}:
            return (
                f" Payments to your credit card from this account (${paid:.0f}) aren't counted "
                "as spending; those purchases count on the card."
            )
        return ""
    paid = sum(float(r.get("card_payments_in", 0) or 0) for r in rows)
    if paid >= 1 and metric in {"income", "net", "both"}:
        return (
            f" Income leaves out ${paid:.0f} of credit card payments, which only move money "
            "between your own accounts."
        )
    return ""


def _missing_month_reply(target, month_index):
    """A month before the data starts or still in the future; None for anything else
    ("2026-13" is left to the invalid-period clarification)."""
    valid_month = re.match(r"^20\d{2}-(0[1-9]|1[0-2])$", target or "")
    if valid_month and month_index and target < min(month_index):
        return {
            "reply": (
                f"Your data starts in {min(month_index)}, so there's nothing recorded for {target}."
            ),
            "insights": ["Only months since your accounts were connected have data."],
            "actions": [f"Ask about any month from {min(month_index)} on."],
            "missing_fields": [],
            "facts_used": [],
            "period_resolved": target,
        }
    if valid_month and target > date_cls.today().strftime("%Y-%m"):
        return {
            "reply": f"{target} hasn't happened yet, so there's no spending or income for it.",
            "insights": ["Only past and current months have recorded totals."],
            "actions": ["Ask how much you might spend next month for an estimate."],
            "missing_fields": [],
            "facts_used": [],
            "period_resolved": target,
        }
    return None


def _exec_amount_month(query_spec, summary, scope_label):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    target = query_spec.period_key
    if not target:
        return None
    row = month_index.get(target)
    if not isinstance(row, dict):
        return _missing_month_reply(target, month_index)
    metric = query_spec.metric
    if metric not in {"income", "expenses", "net", "both"}:
        metric = "expenses"
    if metric == "both":
        income = float(row.get("income", 0) or 0)
        expenses = float(row.get("expenses", 0) or 0)
        net = income - expenses
        sign = "+" if net >= 0 else "-"
        if target == date_cls.today().strftime("%Y-%m"):
            words = ("So far in", "has income", "is")
        else:
            words = ("For", "had income", "was")
        return {
            "reply": (
                f"{words[0]} {target}, {scope_label} {words[1]} of about ${income:.0f} and "
                f"expenses of about ${expenses:.0f}, so net cash flow {words[2]} "
                f"{sign}${abs(net):.0f}.{_card_payment_note(summary, [row], 'both')}"
            ),
            "insights": ["Amounts derived directly from validated summary indexes."],
            "actions": ["Ask a follow-up for category or day-level breakdown if needed."],
            "missing_fields": [],
            "facts_used": ["month_index.income", "month_index.expenses"],
            "period_resolved": target,
        }
    if metric == "net":
        income = float(row.get("income", 0) or 0)
        expenses = float(row.get("expenses", 0) or 0)
        net = income - expenses
        sign = "+" if net >= 0 else "-"
        reply = (
            f"For {target}, net cash flow for {scope_label} is about {sign}${abs(net):.0f} "
            f"(income ${income:.0f} minus expenses ${expenses:.0f})."
        )
        if query_spec.reason_mode == "earn_vs_spend" and query_spec.compare_to == "break_even":
            if abs(net) < max(25.0, 0.02 * float(row.get("income", 0) or 0)):
                verdict = "Yes, about even."
            elif net > 0:
                verdict = f"Better than even: you earned ${net:.0f} more than you spent."
            else:
                verdict = f"No, you spent ${-net:.0f} more than you earned."
            reply = f"{verdict} {reply}"
        elif query_spec.reason_mode == "earn_vs_spend":
            reply = f"{_earn_vs_spend_verdict(query_spec, net)} {reply}"
        reply += _card_payment_note(summary, [row], "net")
        return {
            "reply": reply,
            "insights": ["Amount derived directly from validated summary indexes."],
            "actions": ["Ask a follow-up for category or day-level breakdown if needed."],
            "missing_fields": [],
            "facts_used": ["month_index.income", "month_index.expenses"],
            "period_resolved": target,
        }
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
        cats = row.get("categories")
        if isinstance(cats, dict):
            # Transfers and payments count in the total but aren't split by category; say
            # so when they're most of it (common for a checking account).
            unsplit = amount - sum(float(v or 0) for v in cats.values())
            if unsplit >= amount - 0.5 and amount >= 10:
                reply += " All of it is transfers and payments, which aren't split by category."
            elif unsplit >= 10 and unsplit >= amount * 0.25:
                reply += (
                    f" About ${unsplit:.0f} of that is transfers and payments, which aren't "
                    "split by category."
                )
    else:
        reply = f"For {target}, total income for {scope_label} is about ${amount:.0f}."
        if query_spec.reason_mode == "income_vs_usual":
            reply += _income_vs_usual(summary, target)
    reply += _card_payment_note(summary, [row], metric)

    return {
        "reply": reply,
        "insights": ["Amount derived directly from validated summary indexes."],
        "actions": ["Ask a follow-up for category or day-level breakdown if needed."],
        "missing_fields": [],
        "facts_used": [f"month_index.{metric}"],
        "period_resolved": target,
    }


def _merged_row(month_index, keys):
    """Several months as one row: income, spending, counts and categories added up."""
    rows = [month_index[k] for k in keys if isinstance(month_index.get(k), dict)]
    if not rows:
        return None
    merged = {"income": 0.0, "expenses": 0.0, "tx_count": 0, "expense_tx_count": 0}
    categories = {}
    for row in rows:
        for field in merged:
            merged[field] += row.get(field, 0) or 0
        for name, amount in (row.get("categories") or {}).items():
            categories[str(name)] = categories.get(str(name), 0.0) + float(amount or 0)
    if all(isinstance(r.get("categories"), dict) for r in rows):
        merged["categories"] = categories
    return merged


def _in_period(target):
    """ "In 2026-09", or "From 2026-07 to 2026-09" for a span."""
    return f"From {target}" if " to " in target else f"In {target}"


def _span_label(month_index, keys):
    present = [k for k in keys if k in month_index]
    if not present:
        return ""
    return present[0] if len(present) == 1 else f"{present[0]} to {present[-1]}"


def _exec_category_month(query_spec, summary, scope_label):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    target = query_spec.period_key
    category = query_spec.category
    if query_spec.period_type == "month_range":
        # "food or shopping in q3": the months added up
        keys = [k for k in target.split(",") if k]
        row = _merged_row(month_index, keys)
        if row is None:
            return None
        target = _span_label(month_index, keys)
        month_index = {**month_index, target: row}
    row = month_index.get(target)
    if not isinstance(row, dict):
        return _missing_month_reply(target, month_index)
    # Older app builds send no per-month categories; let the general path answer.
    if not isinstance(row.get("categories"), dict):
        return None
    amounts = {str(k).lower(): float(v or 0) for k, v in row["categories"].items()}
    names = [n.strip() for n in category.split(",") if n.strip()]
    total = float(row.get("expenses", 0) or 0)
    if query_spec.reason_mode == "exclude":
        removed = sum(amounts.get(n.lower(), 0.0) for n in names)
        return {
            "reply": (
                f"For {target}, spending for {scope_label} excluding {' and '.join(names)} "
                f"is about ${total - removed:.0f} (total ${total:.0f} minus ${removed:.0f})."
            ),
            "insights": ["Category amounts are read directly from validated month indexes."],
            "actions": ["Ask for any single category's amount for that month."],
            "missing_fields": [],
            "facts_used": ["month_index.expenses", "month_index.categories"],
            "period_resolved": target,
        }
    if len(names) == 2 and query_spec.reason_mode == "versus":
        a, b = (amounts.get(n.lower(), 0.0) for n in names)
        gap = a - b
        if abs(gap) < 1:
            verdict = "about the same"
        else:
            bigger = names[0] if gap > 0 else names[1]
            verdict = f"{bigger} is ${abs(gap):.0f} higher"
        return {
            "reply": (
                f"{_in_period(target)}, {names[0]} is about ${a:.0f} and {names[1]} about ${b:.0f} for "
                f"{scope_label}; {verdict}."
            ),
            "insights": ["Category amounts are read directly from validated month indexes."],
            "actions": ["Ask how either compares with last month."],
            "missing_fields": [],
            "facts_used": ["month_index.categories"],
            "period_resolved": target,
        }
    if len(names) > 1:
        parts = [f"about ${amounts.get(n.lower(), 0.0):.0f} on {n}" for n in names]
        combined = sum(amounts.get(n.lower(), 0.0) for n in names)
        joined = ", ".join(parts[:-1]) + f" and {parts[-1]}"
        return {
            "reply": (
                f"For {target}, {scope_label} spent {joined}; together about "
                f"${combined:.0f} of ${total:.0f} total."
            ),
            "insights": ["Category amounts are read directly from validated month indexes."],
            "actions": ["Ask to compare these categories with another month."],
            "missing_fields": [],
            "facts_used": ["month_index.categories"],
            "period_resolved": target,
        }
    category = names[0] if names else category
    amount = amounts.get(category.lower(), 0.0)
    term = (query_spec.compare_to or "").strip()
    lead = f"{term.title()} isn't tracked separately; it's part of {category}. " if term else ""
    if query_spec.reason_mode in {"share", "share_of_income"}:
        base = total
        base_label = "total spending"
        if query_spec.reason_mode == "share_of_income":
            base = float(row.get("income", 0) or 0)
            base_label = "income"
        if base <= 0:
            return None
        if amount < 1:
            return _pointer(
                f"I don't see any {category} spending for {scope_label} in {target}.",
                "Ask about another category or month.",
            )
        pct = amount / base * 100
        share = "under 1%" if pct < 1 else f"{pct:.0f}%"
        return {
            "reply": (
                f"{lead}{_in_period(target)}, {category} was about ${amount:.0f}, which is "
                f"{share} of your {base_label} (${base:.0f})."
            ),
            "insights": ["Shares are read directly from validated month indexes."],
            "actions": [f"Ask how {category}'s share compares with other months."],
            "missing_fields": [],
            "facts_used": ["month_index.categories", "month_index.expenses"],
            "period_resolved": target,
        }
    if query_spec.reason_mode == "counterfactual":
        return {
            "reply": (
                f"Skipping {category} in {target} would have saved about ${amount:.0f} "
                f"for {scope_label}, leaving that month's spending near ${total - amount:.0f}."
            ),
            "insights": ["Category amount is read directly from validated month indexes."],
            "actions": [f"Ask how {category} in {target} compares with your usual month."],
            "missing_fields": [],
            "facts_used": ["month_index.categories"],
            "period_resolved": target,
        }
    if amount > 0:
        pct = amount / total * 100 if total > 0 else 0
        pct_text = "under 1%" if 0 < pct < 1 else f"{pct:.0f}%"
        share = f" ({pct_text} of ${total:.0f} total)" if total > 0 else ""
        reply = (
            f"{lead}For {target}, {category} spending for {scope_label} is about "
            f"${amount:.0f}{share}."
        )
    else:
        reply = f"{lead}I don't see any {category} spending for {target} for {scope_label}."
    return {
        "reply": reply,
        "insights": ["Category amount is read directly from validated month indexes."],
        "actions": [f"Ask for {category} transactions or another month to compare."],
        "missing_fields": [],
        "facts_used": ["month_index.categories"],
        "period_resolved": target,
    }


def _month_amount(row, category):
    if not isinstance(row, dict):
        return None
    if not category:
        return float(row.get("expenses", 0) or 0)
    cats = row.get("categories")
    if not isinstance(cats, dict):
        return None
    lowered = {str(k).lower(): float(v or 0) for k, v in cats.items()}
    return lowered.get(category.lower(), 0.0)


def _exec_range_judgement(query_spec, summary, scope_label):
    """ "is that a lot?" after a span of months: its monthly average against the other
    full months."""
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    category = query_spec.category
    current = date_cls.today().strftime("%Y-%m")
    keys = [k for k in query_spec.period_key.split(",") if k in month_index and k != current]
    others = [k for k in month_index if k not in keys and k != current]
    if not keys or not others:
        return None
    values = [_month_amount(month_index[k], category) for k in keys]
    usual_values = [_month_amount(month_index[k], category) for k in others]
    if any(v is None for v in values + usual_values):
        return None
    avg = sum(values) / len(values)
    usual = sum(usual_values) / len(usual_values)
    span = keys[0] if len(keys) == 1 else f"{keys[0]} to {keys[-1]}"
    subject = f"on {category}" if category else "in total"
    gap = avg - usual
    if abs(gap) < max(1.0, 0.1 * usual):
        verdict = f"That's about your usual ${usual:.0f} a month."
    else:
        verdict = (
            f"That's {'above' if gap > 0 else 'below'} the ${usual:.0f} a month of your other "
            f"months, by about ${abs(gap):.0f}."
        )
    return {
        "reply": (
            f"From {span} you spent about ${sum(values):.0f} {subject} for {scope_label}, "
            f"about ${avg:.0f} a month. {verdict}"
        ),
        "insights": ["Usual = the average of your other full months."],
        "actions": ["Ask which month in that span was highest."],
        "missing_fields": [],
        "facts_used": ["month_index"],
        "period_resolved": span,
    }


def _exec_spend_allowance(query_spec, summary, scope_label):
    """ "how much can I spend per day for the rest of october to stay under $2000" """
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    target = query_spec.period_key
    today = date_cls.today()
    if target != today.strftime("%Y-%m"):
        return None
    category = query_spec.category
    spent = _month_amount(month_index.get(target), category) or 0.0
    limit = float(query_spec.compare_to.split(":")[1])
    days_in_month = calendar.monthrange(today.year, today.month)[1]
    days_left = days_in_month - today.day + 1
    subject = f" on {category}" if category else ""
    left = limit - spent
    if left <= 0:
        reply = (
            f"You've already spent ${spent:.0f}{subject} in {target} for {scope_label}, about "
            f"${abs(left):.0f} over ${limit:.0f}, so there's nothing left to stay under it."
        )
    else:
        reply = (
            f"To stay under ${limit:.0f}{subject} in {target}, you can spend about ${left:.0f} "
            f"more for {scope_label}, about ${left / days_left:.0f} a day for the {days_left} "
            f"days left (you've spent ${spent:.0f} so far)."
        )
    return {
        "reply": reply,
        "insights": [
            "Left = the limit minus this month's spending so far, spread over the days left."
        ],
        "actions": ["Set that amount as a limit in the Budget tab."],
        "missing_fields": [],
        "facts_used": ["month_index.expenses"],
        "period_resolved": target,
    }


def _exec_pace_check(query_spec, summary, scope_label):
    """This month (projected if still running) against the average of the three full
    months before it."""
    if query_spec.period_type == "month_range":
        return _exec_range_judgement(query_spec, summary, scope_label)
    if (query_spec.compare_to or "").startswith("allowance:"):
        return _exec_spend_allowance(query_spec, summary, scope_label)
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    target = query_spec.period_key
    category = query_spec.category
    spent = _month_amount(month_index.get(target), category)
    if spent is None:
        return None
    history = []
    month = target
    while len(history) < 3:
        month = _prev_month_key(month)
        if not month or month not in month_index:
            break
        value = _month_amount(month_index[month], category)
        if value is None:
            break
        history.append(value)
    if not history:
        return None
    usual = sum(history) / len(history)
    subject = f"on {category}" if category else "in total"
    today = date_cls.today()
    projected = spent
    progress = ""
    spent_words = "you've spent" if target == today.strftime("%Y-%m") else "you spent"
    if target == today.strftime("%Y-%m"):
        days_in_month = calendar.monthrange(today.year, today.month)[1]
        projected = spent / today.day * days_in_month if today.day else spent
        progress = f" ({today.day} of {days_in_month} days), on pace for about ${projected:.0f}"
    if (query_spec.compare_to or "").startswith("amount:"):
        parts = query_spec.compare_to.split(":")
        limit = float(parts[1])
        asked_under = len(parts) > 2 and parts[2] == "under"
        gap = projected - limit
        side = "over" if gap > 0 else "under"
        yes = (gap < 0) if asked_under else (gap > 0)
        if progress:
            verdict = f"That would land about ${abs(gap):.0f} {side} ${limit:.0f}."
            answer = "Probably yes. " if yes else "Probably not. "
        else:
            verdict = f"That's about ${abs(gap):.0f} {side} ${limit:.0f}."
            answer = "Yes. " if yes else "No. "
        return {
            "reply": (
                f"{answer}In {target} {spent_words} ${spent:.0f} {subject} for {scope_label}"
                f"{progress}. {verdict}"
            ),
            "insights": ["Projection assumes the rest of the month runs at today's pace."],
            "actions": ["Set that amount as a limit in the Budget tab."],
            "missing_fields": [],
            "facts_used": ["month_index.expenses"],
            "period_resolved": target,
        }
    if query_spec.compare_to == "last_month":
        last = _month_amount(month_index.get(_prev_month_key(target)), category)
        if last is not None and last > 0:
            if projected < last:
                verdict = f"That's on track to come in under last month's ${last:.0f}."
            else:
                verdict = f"That's on track to come in above last month's ${last:.0f}."
            return {
                "reply": (
                    f"In {target} {spent_words} ${spent:.0f} {subject} for {scope_label}"
                    f"{progress}. {verdict}"
                ),
                "insights": ["Projection assumes the rest of the month runs at today's pace."],
                "actions": ["Ask which category is driving the difference."],
                "missing_fields": [],
                "facts_used": ["month_index.expenses"],
                "period_resolved": target,
            }
    if spent < 1 and usual < 5 and category:
        return _pointer(
            f"You didn't spend anything on {category} for {scope_label} in {target}, and you "
            f"usually spend little or nothing there (about ${usual:.0f} a month).",
            f"Ask which months had {category} spending.",
        )
    if usual <= 0 and spent < 1:
        verdict = "You don't usually spend anything here either."
    elif usual <= 0:
        verdict = "You don't usually spend anything here, so any spending is above normal."
    elif projected > usual * 1.1:
        gap = projected - usual
        verdict = f"That's above your usual ${usual:.0f} a month, by about ${gap:.0f}."
    elif projected < usual * 0.9:
        gap = usual - projected
        verdict = f"That's below your usual ${usual:.0f} a month, by about ${gap:.0f}."
    else:
        verdict = f"That's close to your usual ${usual:.0f} a month."
    return {
        "reply": (
            f"In {target} {spent_words} ${spent:.0f} {subject} for {scope_label}{progress}. "
            f"{verdict}"
        ),
        "insights": [f"Usual = average of the {len(history)} full months before {target}."],
        "actions": ["Ask for tips to cut this category if it is above usual."],
        "missing_fields": [],
        "facts_used": ["month_index.categories" if category else "month_index.expenses"],
        "period_resolved": target,
    }


def _category_deltas(before_row, after_row, after_factor=1.0):
    """[(category, after - before)] largest absolute change first, when both months
    carry per-category spend. after_factor projects a month still in progress."""
    before = before_row.get("categories") if isinstance(before_row, dict) else None
    after = after_row.get("categories") if isinstance(after_row, dict) else None
    if not isinstance(before, dict) or not isinstance(after, dict):
        return []
    names = {str(k) for k in before} | {str(k) for k in after}
    deltas = [
        (name, float(after.get(name, 0) or 0) * after_factor - float(before.get(name, 0) or 0))
        for name in names
    ]
    return sorted((d for d in deltas if abs(d[1]) >= 1), key=lambda d: -abs(d[1]))


def _exec_category_change(query_spec, summary, scope_label):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    parts = [x.strip() for x in (query_spec.period_key or "").split(",") if x.strip()]
    if len(parts) != 2:
        return None
    if query_spec.period_type == "quarters":
        # "which category grew the most between spring and summer": each one added up
        current = date_cls.today().strftime("%Y-%m")
        merged = {}
        for label in parts:
            keys = group_months(label)
            if current in keys or not all(k in month_index for k in keys):
                return _pointer(
                    f"{_cap(_group_name(label))} isn't complete in your data, so I can't compare "
                    "its categories fairly.",
                    "Ask about two full months instead.",
                )
            merged[_group_name(label)] = _merged_row(month_index, keys)
        parts = list(merged)
        month_index = {**month_index, **merged}
        left, right = parts
        factor, progress = 1.0, None
    else:
        left, right = sorted(parts)
        factor, progress = _month_scale(right)
    deltas = _category_deltas(month_index.get(left), month_index.get(right), after_factor=factor)
    if not deltas:
        rows = [month_index.get(left), month_index.get(right)]
        if all(isinstance(r, dict) and isinstance(r.get("categories"), dict) for r in rows):
            # An account whose spending is all transfers and payments has no categories.
            return _pointer(
                f"{scope_label} has no spending split by category in {left} or {right}, so "
                "there's no category change to compare.",
                "Ask for the total spending in either month.",
            )
        return None
    rising = query_spec.reason_mode != "down"
    pick = [d for d in deltas if (d[1] > 0) == rising]
    if query_spec.reason_mode == "any" and deltas:
        # "changed the most": the biggest move either way.
        name, diff = max(deltas, key=lambda d: abs(d[1]))
        word = "rose" if diff > 0 else "fell"
        reply = (
            f"From {left} to {right}, {name} changed the most for {scope_label}: it {word} by "
            f"about ${abs(diff):.0f}."
        )
        pick = None
    if pick is None:
        pass
    elif not pick:
        word = "grew" if rising else "dropped"
        reply = f"No category {word} from {left} to {right} for {scope_label}."
    else:
        name, diff = max(pick, key=lambda d: abs(d[1]))
        word = "grew the most" if rising else "dropped the most"
        reply = (
            f"From {left} to {right}, {name} {word} for {scope_label}: "
            f"{'+' if diff > 0 else '-'}${abs(diff):.0f}."
        )
    if not progress:
        # An account that is mostly transfers: its biggest move may have no category.
        spent = [float(month_index[k].get("expenses", 0) or 0) for k in (left, right)]
        unsplit = spent[1] - spent[0] - sum(d for _, d in deltas)
        if abs(unsplit) >= 50 and abs(unsplit) > max(abs(d) for _, d in deltas):
            reply += (
                f" Transfers and payments, which aren't split by category, "
                f"{'rose' if unsplit > 0 else 'fell'} by about ${abs(unsplit):.0f}."
            )
    if progress:
        reply = (
            f"{reply} {right} isn't over yet ({progress[0]} of {progress[1]} days), so it's "
            "compared at its projected full-month totals."
        )
    return {
        "reply": reply,
        "insights": ["Category changes are read directly from validated month indexes."],
        "actions": [f"Ask how much you spent on a category in {right} for detail."],
        "missing_fields": [],
        "facts_used": ["month_index.categories"],
        "period_resolved": f"{left} vs {right}",
    }


def _exec_spending_trend(query_spec, summary, scope_label):
    keys, month_index = _recent_full_months(summary)
    note = ""
    if query_spec.period_type == "month_range":
        # "average between may and august": those months, without the one still running.
        current = date_cls.today().strftime("%Y-%m")
        wanted = [k for k in (query_spec.period_key or "").split(",") if k]
        keys = sorted((k for k in wanted if k in month_index and k != current), reverse=True)
        if current in wanted and current in month_index:
            note = f" {current} is left out because it isn't over yet."
        if not keys and wanted:
            missing = _missing_month_reply(wanted[0], month_index) or _missing_month_reply(
                wanted[-1], month_index
            )
            if missing:
                return missing
    if query_spec.period_type == "year" and query_spec.reason_mode != "per_quarter":
        # "average per month this year": every full month of the year, not just the last 3.
        current = _selected_month(summary)
        keys = sorted(
            (
                k
                for k in month_index
                if str(k).startswith(f"{query_spec.period_key}-") and k < current
            ),
            reverse=True,
        )
        if current and current.startswith(f"{query_spec.period_key}-"):
            note = f" {current} is left out because it isn't over yet."
    if not keys:
        return None
    category = query_spec.category
    metric = query_spec.metric if query_spec.metric in {"income", "net"} else "expenses"
    values = []
    for key in keys:
        row = month_index[key]
        if category:
            amount = _month_amount(row, category)
        elif metric == "net":
            amount = float(row.get("income", 0) or 0) - float(row.get("expenses", 0) or 0)
        else:
            amount = float(row.get(metric, 0) or 0)
        if amount is None:
            return None
        values.append(amount)
    if category:
        subject = f"{category} spending"
    else:
        subject = {"income": "income", "net": "savings (income minus spending)"}.get(
            metric, "spending"
        )
    avg = sum(values) / len(values)
    span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
    oldest_first = list(zip(reversed(keys), reversed(values)))
    if metric == "net" and not category:
        # Savings can be negative: "+$631", "-$776".
        series = ", ".join(f"{k} {'+' if v >= 0 else '-'}${abs(v):.0f}" for k, v in oldest_first)
    else:
        series = ", ".join(f"{k} ${v:.0f}" for k, v in oldest_first)
    if (
        category
        and query_spec.reason_mode in {"average", "trend", "per_week", "per_year"}
        and all(v < 1 for v in values)
    ):
        return _pointer(
            f"I don't see any {category} spending for {scope_label} over {span}.",
            f"Ask how much you spent on {category} this month.",
        )
    if query_spec.reason_mode == "habits":
        averages = {}
        for key in keys:
            cats = month_index[key].get("categories")
            for name, amount in cats.items() if isinstance(cats, dict) else []:
                averages[str(name)] = averages.get(str(name), 0.0) + float(amount or 0) / len(keys)
        top = sorted(averages.items(), key=lambda kv: -kv[1])[:3]
        listed = ", ".join(f"{name} about ${amount:.0f}" for name, amount in top)
        reply = f"Over {span}, you spent about ${avg:.0f} a month for {scope_label}."
        if listed:
            reply += f" Most of it goes to {listed} a month."
        current = _selected_month(summary)
        row = month_index.get(current)
        if isinstance(row, dict):
            factor, progress = _month_scale(current)
            pace = float(row.get("expenses", 0) or 0) * factor
            if progress:
                word = "below" if pace < avg else "above"
                reply += f" {current} is on pace for about ${pace:.0f}, {word} that usual level."
        return {
            "reply": reply,
            "insights": ["Averages over your recent full months."],
            "actions": ["Ask for tips to cut your biggest category."],
            "missing_fields": [],
            "facts_used": ["month_index.expenses", "month_index.categories"],
            "period_resolved": span,
        }
    if query_spec.reason_mode == "per_quarter":
        # each quarter of the year added up; full quarters set the average
        current = date_cls.today().strftime("%Y-%m")
        totals = []
        for part in range(1, 5):
            months = [
                m
                for m in group_months(f"{query_spec.period_key}-Q{part}")
                if m in month_index and m != current
            ]
            if not months:
                continue
            value = 0.0
            for m in months:
                r = month_index[m]
                if category:
                    value += _month_amount(r, category) or 0.0
                elif metric == "net":
                    value += float(r.get("income", 0) or 0) - float(r.get("expenses", 0) or 0)
                else:
                    value += float(r.get(metric, 0) or 0)
            totals.append((f"Q{part}", value, len(months) == 3))
        if not totals:
            return None
        full = [q for q in totals if q[2]]
        used = full or totals
        listed = ", ".join(f"{q} ${v:.0f}{'' if whole else ' (part)'}" for q, v, whole in totals)
        what = f"{category} spending" if category else subject
        caveat = "" if full else " None of them is a full quarter in your data yet."
        return {
            "reply": (
                f"Your {what} for {scope_label} averages about "
                f"${sum(v for _, v, _ in used) / len(used):.0f} a quarter in "
                f"{query_spec.period_key} ({listed}).{caveat}"
            ),
            "insights": ["Quarters with all three months in your data set the average."],
            "actions": ["Ask which quarter was highest."],
            "missing_fields": [],
            "facts_used": ["month_index"],
            "period_resolved": query_spec.period_key,
        }
    if query_spec.reason_mode == "per_year":
        monthly = sum(values) / len(values)
        span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
        what = f" on {category}" if category else ""
        return {
            "reply": (
                f"At your recent pace, that's about ${monthly * 12:.0f} a year{what} for "
                f"{scope_label} (${monthly:.0f} a month on average, {span})."
            ),
            "insights": ["Yearly = monthly average x 12."],
            "actions": ["Ask how much you've spent so far this year."],
            "missing_fields": [],
            "facts_used": ["month_index"],
            "period_resolved": span,
        }
    if query_spec.reason_mode == "per_week":
        weekly = sum(values) / len(values) * 12 / 52
        span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
        what = f" on {category}" if category else ""
        return {
            "reply": (
                f"You spend about ${weekly:.0f} a week{what} for {scope_label} "
                f"(${sum(values) / len(values):.0f} a month on average, {span})."
            ),
            "insights": ["Weekly = monthly average x 12 / 52."],
            "actions": ["Ask how this week compares with last week."],
            "missing_fields": [],
            "facts_used": ["month_index"],
            "period_resolved": span,
        }
    if query_spec.reason_mode == "volatility":
        all_keys = sorted(k for k in month_index if k != date_cls.today().strftime("%Y-%m"))
        if query_spec.period_type == "month_range":
            # "was my income steady over the summer": just those months
            wanted = set(query_spec.period_key.split(","))
            all_keys = [k for k in all_keys if k in wanted]
        series_values = []
        for key in all_keys:
            row = month_index[key]
            amount = _month_amount(row, category) if category else float(row.get(metric, 0) or 0)
            if amount is not None:
                series_values.append((key, amount))
        if len(series_values) < 3:
            return None
        nums = [v for _, v in series_values]
        mean = sum(nums) / len(nums)
        spread = (sum((v - mean) ** 2 for v in nums) / len(nums)) ** 0.5
        low = min(series_values, key=lambda kv: kv[1])
        high = max(series_values, key=lambda kv: kv[1])
        if spread < mean * 0.15:
            level = "fairly steady"
        elif spread < mean * 0.3:
            level = "somewhat uneven"
        else:
            level = "quite uneven"
        return {
            "reply": (
                f"Your monthly {subject} for {scope_label} is {level}: it averages about "
                f"${mean:.0f} and typically moves about ${spread:.0f} either way, from "
                f"${low[1]:.0f} ({low[0]}) to ${high[1]:.0f} ({high[0]})."
            ),
            "insights": [f"Based on {len(nums)} full months."],
            "actions": ["Ask why the highest month was high."],
            "missing_fields": [],
            "facts_used": ["month_index"],
            "period_resolved": f"{all_keys[0]} to {all_keys[-1]}",
        }
    if query_spec.reason_mode == "trend" and len(values) >= 2:
        # Long spans compare the first half's average with the second half's, so one
        # odd month at either end doesn't set the direction.
        half = len(oldest_first) // 2
        first = sum(v for _, v in oldest_first[:half]) / half
        last = sum(v for _, v in oldest_first[-half:]) / half
        if first and abs(last - first) / abs(first) < 0.1:
            direction = "roughly flat"
        else:
            direction = "going up" if last > first else "going down"
        verb = "have" if subject.startswith("savings") else "has"
        reply = f"Your {subject} for {scope_label} {verb} been {direction} recently: {series}."
        if query_spec.period_type in {"year", "month_range"}:
            reply = (
                f"Over {span}, your {subject} for {scope_label} {verb} been {direction}: {series}."
            )
        current = _selected_month(summary)
        row_now = month_index.get(current) if isinstance(month_index, dict) else None
        if (
            metric == "income"
            and not category
            and isinstance(row_now, dict)
            and current not in keys
        ):
            # Income lands in lumps, so say where the running month already stands.
            so_far = float(row_now.get("income", 0) or 0)
            last_full = oldest_first[-1][1]
            side = "above" if so_far > last_full else "below"
            reply += (
                f" {current} so far is ${so_far:.0f}, already {side} {oldest_first[-1][0]}."
                if so_far > last_full
                else f" {current} so far is ${so_far:.0f}, {side} {oldest_first[-1][0]} so far."
            )
        if len(oldest_first) >= 3 and direction != "roughly flat":
            (prev_key, prev), (last_key, last_value) = oldest_first[-2], oldest_first[-1]
            step = last_value - prev
            if abs(step) >= max(1.0, 0.05 * abs(prev)) and (step > 0) != (direction == "going up"):
                moved = "rose" if step > 0 else "dipped"
                word = "up" if step > 0 else "down"
                reply += f" It {moved} in {last_key}, {word} ${abs(step):.0f} from {prev_key}."
    else:
        shown = f"{'+' if avg >= 0 else '-'}${abs(avg):.0f}" if metric == "net" else f"${avg:.0f}"
        verb = "are" if subject.startswith("savings") else "is"
        reply = (
            f"Your average monthly {subject} for {scope_label} {verb} about {shown}, "
            f"over {span} ({series}).{note}"
        )
    return {
        "reply": reply,
        "insights": [f"Based on the {len(values)} full months before {query_spec.period_key}."],
        "actions": ["Ask whether this month is on pace compared with that average."],
        "missing_fields": [],
        "facts_used": ["month_index.categories" if category else f"month_index.{metric}"],
        "period_resolved": span,
    }


def _exec_hotspots(query_spec, summary, scope_label):
    """Categories running above their usual level this month, else the biggest ones."""
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    target = query_spec.period_key
    row = month_index.get(target)
    cats = row.get("categories") if isinstance(row, dict) else None
    if not isinstance(cats, dict) or not cats:
        return None
    keys, _ = _recent_full_months(summary)
    scale = 1.0
    today = date_cls.today()
    if target == today.strftime("%Y-%m") and today.day:
        scale = calendar.monthrange(today.year, today.month)[1] / today.day
    above = []
    for name, amount in cats.items():
        history = [_month_amount(month_index[k], str(name)) or 0.0 for k in keys]
        usual = sum(history) / len(history) if history else 0.0
        projected = float(amount or 0) * scale
        if usual > 0 and projected > usual * 1.15 and projected - usual >= 20:
            above.append((str(name), projected, usual))
    above.sort(key=lambda x: -(x[1] - x[2]))
    if above:
        listed = "; ".join(
            f"{name} on pace for ${projected:.0f} vs usual ${usual:.0f}"
            for name, projected, usual in above[:3]
        )
        ranked = sorted(((str(k), float(v or 0)) for k, v in cats.items()), key=lambda kv: -kv[1])
        biggest = ", ".join(f"{k} ${v:.0f}" for k, v in ranked[:3])
        reply = (
            f"Running above your usual in {target} for {scope_label}: {listed}. Your biggest "
            f"categories are {biggest}, so those are where cuts count most."
        )
    else:
        ranked = sorted(((str(k), float(v or 0)) for k, v in cats.items()), key=lambda kv: -kv[1])
        listed = ", ".join(f"{k} ${v:.0f}" for k, v in ranked[:3])
        reply = (
            f"Nothing in {target} is running above your usual level. Your biggest "
            f"categories for {scope_label} are {listed}, so those are where cuts count most."
        )
    return {
        "reply": reply,
        "insights": ["Usual = average of your recent full months for each category."],
        "actions": ["Ask for tips to cut one of these categories."],
        "missing_fields": [],
        "facts_used": ["month_index.categories"],
        "period_resolved": target,
    }


def _exec_amount_rolling(query_spec, summary, scope_label):
    windows = summary.get("windows_rolling")
    days = (query_spec.period_key or "").replace("rolling_", "").replace("d", "")
    if not isinstance(windows, dict) or f"last_{days}d" not in windows:
        return None
    row = windows[f"last_{days}d"]
    metric = "income" if query_spec.metric == "income" else "expenses"
    amount = float(row.get(metric, 0) or 0)
    return {
        "reply": (
            f"Over the last {days} days, total {metric} for {scope_label} "
            f"{'are' if metric == 'expenses' else 'is'} about ${amount:.0f}."
        ),
        "insights": ["Amount derived directly from validated rolling windows."],
        "actions": ["Ask for a category breakdown of that period."],
        "missing_fields": [],
        "facts_used": [f"windows_rolling.last_{days}d.{metric}"],
        "period_resolved": f"last {days} days",
    }


def _exec_amount_month_range(query_spec, summary, scope_label):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    keys = [x.strip() for x in (query_spec.period_key or "").split(",") if x.strip()]
    if not keys:
        return None
    metric = "income" if query_spec.metric == "income" else "expenses"
    category = (query_spec.category or "").strip()
    present = [k for k in keys if isinstance(month_index.get(k), dict)]
    if not present:
        return None

    def amount_in(key):
        if category:
            return _month_amount(month_index[key], category) or 0.0
        return float(month_index[key].get(metric, 0) or 0)

    span = f"{keys[0]} to {keys[-1]}"
    if query_spec.metric == "net" and not category:
        current = date_cls.today().strftime("%Y-%m")
        if present != keys:
            span = present[0] if len(present) == 1 else f"{present[0]} to {present[-1]}"
        if present[-1] == current:
            span += " so far"
        income = sum(float(month_index[k].get("income", 0) or 0) for k in present)
        spent = sum(float(month_index[k].get("expenses", 0) or 0) for k in present)
        net = income - spent
        missing = [k for k in keys if k not in present]
        future = [k for k in missing if k > current]
        note = ""
        if future:
            names = future[0] if len(future) == 1 else f"{future[0]} to {future[-1]}"
            note = f" ({names} {'hasn' if len(future) == 1 else 'haven'}'t happened yet.)"
        elif missing and month_index and all(k < min(month_index) for k in missing):
            note = f" (Your data starts in {min(month_index)}.)"
        elif missing:
            names = missing[0] if len(missing) == 1 else f"{missing[0]} to {missing[-1]}"
            note = f" ({names} {'has' if len(missing) == 1 else 'have'} no data.)"
        lead = ""
        if query_spec.compare_to in {"positive", "negative"}:
            lead = "Yes. " if (net > 0) == (query_spec.compare_to == "positive") else "No. "
        elif query_spec.compare_to == "judge":
            lead = f"{_earn_vs_spend_verdict(query_spec, net)} "
        return {
            "reply": (
                f"{lead}For {span}, net cash flow for {scope_label} is about "
                f"{'+' if net >= 0 else '-'}${abs(net):.0f} (income ${income:.0f} minus "
                f"expenses ${spent:.0f}).{note}"
            ),
            "insights": ["Net cash flow = income minus expenses, summed over the months."],
            "actions": ["Ask which of those months you saved the most."],
            "missing_fields": [],
            "facts_used": ["month_index.income", "month_index.expenses"],
            "period_resolved": span,
        }
    fact = "month_index.categories" if category else f"month_index.{metric}"
    if category and metric == "expenses":
        metric = f"{category} spending"
    total = sum(amount_in(k) for k in present)
    if present[-1] == date_cls.today().strftime("%Y-%m") and keys[-1] == present[-1]:
        span += " so far"  # "since june": the running month is part of it
    if category and total < 0.5:
        return _pointer(
            f"I don't see any {category} spending for {scope_label} in {span}.",
            f"Ask which months had {category} spending.",
        )
    missing = len(keys) - len(present)
    note = ""
    future = [k for k in keys if k not in present and k > date_cls.today().strftime("%Y-%m")]
    if future:
        names = future[0] if len(future) == 1 else f"{future[0]} to {future[-1]}"
        verb = "hasn't" if len(future) == 1 else "haven't"
        note = f" ({names} {verb} happened yet.)"
    elif missing and month_index and all(k < min(month_index) for k in keys if k not in present):
        note = f" (Your data starts in {min(month_index)}.)"
    elif missing:
        verb = "has" if missing == 1 else "have"
        note = f" ({missing} of those months {verb} no data.)"
    elif len(keys) <= 3:
        # Show each month; months that aren't adjacent ("march and august") are named, not spanned.
        ordinals = [int(k[:4]) * 12 + int(k[5:7]) for k in keys]
        adjacent = all(b - a == 1 for a, b in zip(ordinals, ordinals[1:]))
        if not adjacent:
            span = " and ".join(keys) if len(keys) == 2 else f"{keys[0]}, {keys[1]} and {keys[2]}"
        each = ", ".join(f"${amount_in(k):.0f} in {k}" for k in keys)
        note = f" ({each})."
        verb = "are" if metric == "expenses" else "is"
        return {
            "reply": f"For {span}, total {metric} for {scope_label} {verb} about ${total:.0f}{note}",
            "insights": ["Sum of validated monthly totals."],
            "actions": ["Ask to compare those months."],
            "missing_fields": [],
            "facts_used": [fact],
            "period_resolved": span,
        }
    verb = "are" if metric == "expenses" else "is"
    return {
        "reply": f"For {span}, total {metric} for {scope_label} {verb} about ${total:.0f}.{note}",
        "insights": ["Sum of validated monthly totals."],
        "actions": ["Ask for one month in that range for detail."],
        "missing_fields": [],
        "facts_used": [fact],
        "period_resolved": span,
    }


def _exec_quarter_extreme(query_spec, summary, scope_label):
    """ "which quarter (or season) did I spend the most in": full ones ranked, each listed."""
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    year = query_spec.period_key
    category = query_spec.category
    metric = query_spec.metric if query_spec.metric in {"income", "net"} else "expenses"
    current = date_cls.today().strftime("%Y-%m")
    seasons = query_spec.period_type == "seasons_of_year"
    groups = (
        [
            ("winter", f"{year}-S4"),
            ("spring", f"{year}-S1"),
            ("summer", f"{year}-S2"),
            ("fall", f"{year}-S3"),
        ]
        if seasons
        else [(f"Q{part}", f"{year}-Q{part}") for part in range(1, 5)]
    )
    quarters = []
    for label, group in groups:
        keys = group_months(group)
        present = [k for k in keys if isinstance(month_index.get(k), dict)]
        if not present:
            continue
        total = 0.0
        for key in present:
            row = month_index[key]
            if category:
                total += _month_amount(row, category) or 0.0
            elif metric == "net":
                total += float(row.get("income", 0) or 0) - float(row.get("expenses", 0) or 0)
            else:
                total += float(row.get(metric, 0) or 0)
        full = len(present) == 3 and current not in present
        note = "" if full else (" so far" if current in present else f" (from {present[0]})")
        quarters.append((label, total, full, note))
    if not quarters:
        return None
    signed = metric == "net" and not category

    def money(value):
        return f"{'+' if value >= 0 else '-'}${abs(value):.0f}" if signed else f"${value:.0f}"

    ranked = [q for q in quarters if q[2]] or quarters
    lowest = query_spec.reason_mode == "lowest"
    name, amount, _, _ = (min if lowest else max)(ranked, key=lambda q: q[1])
    if category:
        subject = f"{category} spending"
    else:
        subject = {"income": "income", "net": "savings (income minus spending)"}.get(
            metric, "spending"
        )
    listed = ", ".join(f"{q} {money(v)}{note}" for q, v, _, note in quarters)
    word = "lowest" if lowest else "highest"
    unit = "season" if seasons else "quarter"
    caveat = f" Only full {unit}s are ranked." if len(ranked) < len(quarters) else ""
    return {
        "reply": (
            f"In {year}, {_cap(name)} had your {word} {subject} for {scope_label}, about "
            f"{money(amount)}. By {unit}: {listed}.{caveat}"
        ),
        "insights": ["Each quarter is the sum of its months in the validated month index."],
        "actions": [f"Ask which month in {name} was {word}."],
        "missing_fields": [],
        "facts_used": ["month_index"],
        "period_resolved": year,
    }


def _exec_month_extreme(query_spec, summary, scope_label):
    if query_spec.period_type in {"quarters_of_year", "seasons_of_year"}:
        return _exec_quarter_extreme(query_spec, summary, scope_label)
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    year = query_spec.period_key
    category = query_spec.category
    metric = query_spec.metric if query_spec.metric in {"income", "net"} else "expenses"
    values = []
    span = query_spec.period_type == "month_range"
    wanted = set(year.split(",")) if span else set()
    for key, row in month_index.items():
        if not isinstance(row, dict):
            continue
        if (key not in wanted) if span else not str(key).startswith(f"{year}-"):
            continue
        if category:
            amount = _month_amount(row, category)
        elif metric == "net":
            amount = float(row.get("income", 0) or 0) - float(row.get("expenses", 0) or 0)
        else:
            amount = float(row.get(metric, 0) or 0)
        if amount is not None:
            values.append((str(key), amount))
    if not values:
        return None
    where = f"In {year}"
    if span:
        ordered = sorted(k for k, _ in values)
        where = f"Between {ordered[0]} and {ordered[-1]}"
    lowest = query_spec.reason_mode == "lowest"
    current = date_cls.today().strftime("%Y-%m")
    full = [kv for kv in values if kv[0] != current] or values
    ranked_mode = re.match(r"^(top|bottom):(\d+)$", query_spec.reason_mode or "")
    if ranked_mode:
        # "my three biggest months this year"
        n = int(ranked_mode.group(2))
        bottom = ranked_mode.group(1) == "bottom"
        ordered = sorted(full, key=lambda kv: kv[1], reverse=not bottom)[:n]
        listed = ", ".join(f"{k} ${v:.0f}" for k, v in ordered)
        what = (
            f"{category} spending"
            if category
            else {"income": "income", "net": "savings"}.get(metric, "spending")
        )
        word = "lowest" if bottom else "highest"
        note = (
            f" ({current} is left out because it isn't over yet.)"
            if len(full) < len(values)
            else ""
        )
        return {
            "reply": (
                f"{where}, your {len(ordered)} {word}-{what} months for {scope_label}: {listed}.{note}"
            ),
            "insights": ["Ranked from validated monthly totals."],
            "actions": [f"Ask why {ordered[0][0]} was {'low' if bottom else 'high'}."],
            "missing_fields": [],
            "facts_used": ["month_index"],
            "period_resolved": year,
        }
    key, amount = (min if lowest else max)(full, key=lambda kv: kv[1])
    tied = sorted(k for k, v in full if abs(v - amount) < 1)
    if category and len(tied) >= 3 and amount >= 1 and not query_spec.compare_to:
        # "$33 in every month": no single month stands out
        word = "lowest" if lowest else "highest"
        return _pointer(
            f"{where}, {category} spending for {scope_label} was at its {word}, about "
            f"${amount:.0f}, in {len(tied)} months ({tied[0]} to {tied[-1]}), so no single "
            "month stands out.",
            f"Ask how {category} compares with your other categories.",
            ("month_index.categories",),
        )
    if category:
        subject = f"{category} spending"
    else:
        subject = {"income": "income", "net": "savings (income minus spending)"}.get(
            metric, "spending"
        )
    word = "lowest" if lowest else "highest"
    note = f" ({current} is left out because it isn't over yet.)" if len(full) < len(values) else ""
    claim = query_spec.compare_to
    verdict = ""
    if claim:
        verdict = "Yes. " if claim == key else f"No, not {claim}. "
    return {
        "reply": (
            f"{verdict}{where}, your month with the {word} {subject} for {scope_label} was "
            f"{key}, at about {'-' if amount < 0 else ''}${abs(amount):.0f}.{note}"
        ),
        "insights": ["Ranked from validated monthly totals."],
        "actions": [f"Ask why {key} was {'low' if lowest else 'high'} for a category breakdown."],
        "missing_fields": [],
        "facts_used": ["month_index.categories" if category else f"month_index.{metric}"],
        "period_resolved": year,
    }


def _exec_savings_goal(query_spec, summary, scope_label):
    """Which 20% category cuts add up to a monthly savings goal."""
    try:
        goal = float(query_spec.period_key)
    except (TypeError, ValueError):
        return None
    keys, month_index = _recent_full_months(summary)
    if not keys:
        return None
    if query_spec.reason_mode == "lever":
        return _exec_savings_lever(keys, month_index, scope_label)
    totals = {}
    for key in keys:
        cats = month_index[key].get("categories")
        if not isinstance(cats, dict):
            return None
        for name, amount in cats.items():
            if "transfer" in str(name).lower():
                continue
            totals[str(name)] = totals.get(str(name), 0.0) + float(amount or 0) / len(keys)
    avg_spend = sum(float(month_index[k].get("expenses", 0) or 0) for k in keys) / len(keys)
    if avg_spend <= 0:
        return None
    if sum(totals.values()) < 0.2 * avg_spend:
        return _pointer(
            f"Most of {scope_label}'s spending is transfers and payments, which aren't split by "
            "category, so I can't point to a category to cut. Pick Overall (All Accounts) in "
            "the Account scope menu above the chat to plan savings across everything.",
            "Switch the Account scope to Overall (All Accounts).",
        )
    share = goal / avg_spend * 100
    biggest, biggest_avg = max(totals.items(), key=lambda kv: kv[1])
    if biggest_avg * 0.2 >= goal:
        # One modest trim of the biggest category covers it.
        pct = max(1, math.ceil(goal / biggest_avg * 100))
        return {
            "reply": (
                f"Saving ${goal:.0f} a month means cutting about {share:.0f}% of your usual "
                f"${avg_spend:.0f} monthly spending. The simplest way: trim {biggest}, your "
                f"biggest category, by about {pct}% (about ${goal:.0f} of its usual "
                f"${biggest_avg:.0f} a month)."
            ),
            "insights": [f"Based on average spending over {keys[-1]} to {keys[0]}."],
            "actions": [f"Set a {biggest} limit in the Budget tab."],
            "missing_fields": [],
            "facts_used": ["month_index.categories", "month_index.expenses"],
            "period_resolved": f"{keys[-1]} to {keys[0]}",
        }
    plan, saved = [], 0.0
    for name, avg in sorted(totals.items(), key=lambda kv: -kv[1]):
        if saved >= goal:
            break
        cut = avg * 0.2
        if cut < 5:
            continue
        plan.append(f"{name} by 20% (about ${cut:.0f})")
        saved += cut
    share = goal / avg_spend * 100
    if saved >= goal * 0.95:
        reply = (
            f"Saving ${goal:.0f} a month means cutting about {share:.0f}% of your usual "
            f"${avg_spend:.0f} monthly spending. Cutting {', '.join(plan)} gets you about "
            f"${saved:.0f}."
        )
    else:
        reply = (
            f"Saving ${goal:.0f} a month is about {share:.0f}% of your usual ${avg_spend:.0f} "
            f"monthly spending. Even cutting every category by 20% saves only about "
            f"${saved:.0f}, so you'd need deeper cuts or a smaller goal."
        )
    return {
        "reply": reply,
        "insights": [f"Based on average spending over {keys[-1]} to {keys[0]}."],
        "actions": ["Set these as category limits in the Budget tab."],
        "missing_fields": [],
        "facts_used": ["month_index.categories", "month_index.expenses"],
        "period_resolved": f"{keys[-1]} to {keys[0]}",
    }


def _exec_compare_many(query_spec, keys, summary, scope_label):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    category = query_spec.category
    metric = query_spec.metric if query_spec.metric in {"income", "net"} else "expenses"
    rows = []
    skipped = [k for k in keys if k not in month_index]
    keys = [k for k in keys if k in month_index]
    if not keys:
        if skipped and month_index and skipped[-1] < min(month_index):
            # "and last summer?": before the data starts
            span = skipped[0] if len(skipped) == 1 else f"{skipped[0]} to {skipped[-1]}"
            return _pointer(
                f"Your data starts in {min(month_index)}, so there's nothing recorded for {span}.",
                f"Ask about any month from {min(month_index)} on.",
            )
        return None
    for key in keys:
        row = month_index.get(key)
        if category or metric == "expenses":
            amount = _month_amount(row, category)
        elif not isinstance(row, dict):
            amount = None
        elif metric == "net":
            amount = float(row.get("income", 0) or 0) - float(row.get("expenses", 0) or 0)
        else:
            amount = float(row.get("income", 0) or 0)
        if amount is None:
            return None
        rows.append((key, amount))
    signed = metric == "net" and not category
    if category and all(abs(v) < 0.5 for _, v in rows):
        span = keys[0] if len(keys) == 1 else f"{keys[0]} to {keys[-1]}"
        return _pointer(
            f"I don't see any {category} spending for {scope_label} in {span}.",
            f"Ask which months had {category} spending.",
        )

    def money(value):
        return f"{'+' if value >= 0 else '-'}${abs(value):.0f}" if signed else f"${value:.0f}"

    # Rank a month still in progress by its projected full-month total (not net or
    # income, which don't scale with the days: pay lands in lumps).
    lumpy = signed or (metric == "income" and not category)
    full = rows if lumpy else [(k, v * _month_scale(k)[0]) for k, v in rows]
    high = max(full, key=lambda kv: kv[1])
    low = min(full, key=lambda kv: kv[1])
    if category:
        subject = f"{category} spending"
    else:
        subject = {"income": "Income", "net": "Net cash flow"}.get(metric, "Spending")
    current = date_cls.today().strftime("%Y-%m")
    if lumpy:
        listed = ", ".join(f"{money(v)} {'so far ' if k == current else ''}in {k}" for k, v in rows)
    else:
        listed = ", ".join(_amount_phrase(k, v) for k, v in rows)
    total = sum(v for _, v in rows)
    if lumpy and len(full) > 1 and any(k == current for k, _ in full):
        # a running month's income or savings so far isn't comparable with full months
        full = [kv for kv in full if kv[0] != current]
        high = max(full, key=lambda kv: kv[1])
        low = min(full, key=lambda kv: kv[1])
    if len(rows) == 1:
        extremes = ""
    elif high[1] - low[1] < 1:
        extremes = "About the same each month."
    else:
        extremes = f"Highest was {high[0]} ({money(high[1])}), lowest {low[0]} ({money(low[1])})."
    if skipped:
        future = [k for k in skipped if k > date_cls.today().strftime("%Y-%m")]
        if future:
            span = future[0] if len(future) == 1 else f"{future[0]} to {future[-1]}"
            extremes += f" {span} {'hasn' if len(future) == 1 else 'haven'}'t happened yet."
        if len(future) < len(skipped):
            extremes += f" Your data starts in {min(month_index)}."
    return {
        "reply": f"{subject} for {scope_label}: {listed} (total {money(total)}). {extremes.strip()}".strip(),
        "insights": ["Monthly totals are read directly from validated month indexes."],
        "actions": [f"Ask why {high[0]} was highest for a category breakdown."],
        "missing_fields": [],
        "facts_used": ["month_index.categories" if category else "month_index.expenses"],
        "period_resolved": ", ".join(keys),
    }


def _exec_year_amount(query_spec, summary, scope_label):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    year = query_spec.period_key
    if int(year) > date_cls.today().year:
        return None
    rows = [row for key, row in month_index.items() if str(key).startswith(f"{year}-")]
    names = [n.strip() for n in (query_spec.category or "").split(",") if n.strip()]
    if not rows and month_index and str(year) < min(month_index)[:4]:
        return _pointer(
            f"Your data starts in {min(month_index)}, so there's nothing recorded for {year}.",
            f"Ask about any month from {min(month_index)} on.",
        )
    if not rows:
        return None
    so_far = " so far" if int(year) == date_cls.today().year else ""
    if names:
        parts = []
        for name in names:
            values = [_month_amount(row, name) for row in rows]
            if any(v is None for v in values):
                return None
            parts.append(f"about ${sum(values):.0f} on {name}")
        joined = parts[0] if len(parts) == 1 else ", ".join(parts[:-1]) + f" and {parts[-1]}"
        reply = f"In {year}{so_far}, {scope_label} spent {joined}."
        term = (query_spec.compare_to or "").strip()
        if term and len(names) == 1:
            reply = f"{term.title()} isn't tracked separately; it's part of {names[0]}. {reply}"
        facts = ["month_index.categories"]
    else:
        income = sum(float(r.get("income", 0) or 0) for r in rows)
        expenses = sum(float(r.get("expenses", 0) or 0) for r in rows)
        if query_spec.metric == "income":
            reply = f"In {year}{so_far}, income for {scope_label} is about ${income:.0f}."
        elif query_spec.metric == "net":
            net = income - expenses
            sign = "+" if net >= 0 else "-"
            reply = (
                f"In {year}{so_far}, net cash flow for {scope_label} is about "
                f"{sign}${abs(net):.0f} (income ${income:.0f} minus expenses ${expenses:.0f})."
            )
            if query_spec.reason_mode == "earn_vs_spend":
                reply = f"{_earn_vs_spend_verdict(query_spec, net)} {reply}"
        elif query_spec.metric == "both":
            net = income - expenses
            sign = "+" if net >= 0 else "-"
            reply = (
                f"In {year}{so_far}, {scope_label} had income of about ${income:.0f} and "
                f"expenses of about ${expenses:.0f}, so net cash flow is {sign}${abs(net):.0f}."
            )
        else:
            reply = f"In {year}{so_far}, expenses for {scope_label} are about ${expenses:.0f}."
        reply += _card_payment_note(summary, rows, query_spec.metric)
        facts = [f"month_index.{query_spec.metric}"]
    return {
        "reply": reply,
        "insights": [f"Sum of the {len(rows)} months with data in {year}."],
        "actions": ["Ask for one month of that year for detail."],
        "missing_fields": [],
        "facts_used": facts,
        "period_resolved": year,
    }


def _exec_cap_amount(query_spec, summary, scope_label):
    try:
        cap = float(query_spec.period_key)
    except (TypeError, ValueError):
        return None
    category = query_spec.category
    keys, month_index = _recent_full_months(summary)
    values = [_month_amount(month_index[k], category) for k in keys]
    if not values or any(v is None for v in values):
        return None
    usual = sum(values) / len(values)
    span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
    if cap >= usual:
        reply = (
            f"You already spend about ${usual:.0f} a month on {category} ({span}), so a "
            f"${cap:.0f} limit wouldn't save anything."
        )
    else:
        saved = usual - cap
        reply = (
            f"Keeping {category} to ${cap:.0f} a month would save about ${saved:.0f} a month "
            f"(about ${saved * 12:.0f} a year), against your usual ${usual:.0f} over {span}."
        )
    return {
        "reply": reply,
        "insights": ["Savings are calculated from your recent full months, not estimated."],
        "actions": [f"Set a ${cap:.0f} limit for {category} in the Budget tab."],
        "missing_fields": [],
        "facts_used": ["month_index.categories"],
        "period_resolved": span,
    }


def _exec_affordability(query_spec, summary, scope_label):
    if not query_spec.period_key:
        # "could I afford a trip": no price given, so say what a month leaves over.
        surplus, span = _average_surplus(summary)
        if surplus is None:
            return None
        if surplus > 0:
            reply = (
                f"Your income has beaten your spending by about ${surplus:.0f} a month on average "
                f"({span}), so something costing less than that fits a typical month. Tell me the "
                "price for a clearer answer."
            )
        else:
            reply = (
                f"Recently ({span}) you've spent more than you earned, so a new expense would "
                "need cuts elsewhere. Tell me the price for a clearer answer."
            )
        return _pointer(reply, "Ask again with the price, for example: Can I afford $500?")
    try:
        cost = float(query_spec.period_key)
    except (TypeError, ValueError):
        return None
    keys, month_index = _recent_full_months(summary)
    if not keys:
        return None
    nets = [
        float(month_index[k].get("income", 0) or 0) - float(month_index[k].get("expenses", 0) or 0)
        for k in keys
    ]
    surplus = sum(nets) / len(nets)
    span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
    if surplus >= cost:
        verdict = (
            f"Likely yes: your income has beaten your spending by about ${surplus:.0f} a month "
            f"on average ({span}), more than the ${cost:.0f}."
        )
    elif surplus > 0 and math.ceil(cost / surplus) <= 6:
        verdict = (
            f"It would be tight: your average monthly surplus is about ${surplus:.0f} ({span}), "
            f"short of ${cost:.0f} by about ${cost - surplus:.0f}, so it would take about "
            f"{math.ceil(cost / surplus)} months of that surplus."
        )
    elif surplus > 0:
        months = math.ceil(cost / surplus)
        verdict = (
            f"Not from one month: your income beats your spending by about ${surplus:.0f} a "
            f"month ({span}), so ${cost:.0f} would take about {months} months of that surplus."
        )
    else:
        verdict = (
            f"Not from a typical month: you've spent more than you earned on average over {span}."
        )
    return {
        "reply": (
            f"{verdict} This doesn't include savings or account balances, which chat can't see."
            f"{_card_payments_caveat(summary, keys, month_index)}"
        ),
        "insights": ["Surplus = income minus spending, averaged over recent full months."],
        "actions": ["Ask what to cut to free up the difference."],
        "missing_fields": [],
        "facts_used": ["month_index.income", "month_index.expenses"],
        "period_resolved": span,
    }


def _exec_budget_suggestion(query_spec, summary, scope_label):
    category = query_spec.category
    keys, month_index = _recent_full_months(summary)
    if not keys:
        return None
    if query_spec.reason_mode == "plan":
        totals = {}
        for key in keys:
            cats = month_index[key].get("categories")
            if not isinstance(cats, dict):
                return None
            for name, amount in cats.items():
                totals[str(name)] = totals.get(str(name), 0.0) + float(amount or 0) / len(keys)
        ranked = sorted(
            ((k, v) for k, v in totals.items() if v >= 10 and "transfer" not in k.lower()),
            key=lambda kv: -kv[1],
        )[:6]
        if not ranked:
            return _pointer(
                f"Most of {scope_label}'s spending is transfers and payments, which aren't "
                "split by category, so there's nothing here to build a category budget from. "
                "Pick Overall (All Accounts) in the Account scope menu above the chat.",
                "Switch the Account scope to Overall (All Accounts).",
            )
        lines = "; ".join(
            f"{name} ${usual * 0.9:.0f} (usual ${usual:.0f})" for name, usual in ranked
        )
        total = sum(usual * 0.9 for _, usual in ranked)
        span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
        return {
            "reply": (
                f"A starting plan for next month, 10% below your usual ({span}): {lines}. "
                f"That's about ${total:.0f} across these categories."
            ),
            "insights": ["Usual = average of your recent full months for each category."],
            "actions": ["Enter these limits with Edit Budget on the Budget tab."],
            "missing_fields": [],
            "facts_used": ["month_index.categories"],
            "period_resolved": span,
        }
    if category:
        values = [_month_amount(month_index[k], category) for k in keys]
        if any(v is None for v in values):
            return None
    else:
        values = [float(month_index[k].get("expenses", 0) or 0) for k in keys]
    usual = sum(values) / len(values)
    if usual <= 0:
        return None
    target = usual * 0.9
    subject = category or "total spending"
    span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
    return {
        "reply": (
            f"You usually spend about ${usual:.0f} a month on {subject} ({span}). A budget of "
            f"about ${target:.0f} (10% below that) is a realistic start."
        ),
        "insights": ["Based on your own recent full months."],
        "actions": [f"Set {subject} to about ${target:.0f} in the Budget tab."],
        "missing_fields": [],
        "facts_used": ["month_index.categories" if category else "month_index.expenses"],
        "period_resolved": span,
    }


def _card_payments_caveat(summary, keys, month_index):
    """One bank account's surplus leaves out what it pays to a credit card, so it
    overstates what's free to spend."""
    if summary.get("scope") != "single_account" or credit_card_scope(summary) or not keys:
        return ""
    paid = sum(float(month_index[k].get("card_payments_out", 0) or 0) for k in keys) / len(keys)
    if paid < 1:
        return ""
    return (
        f" This account also paid about ${paid:.0f} a month to your credit card, which isn't "
        "counted here, so pick Overall (All Accounts) to see what you can really afford."
    )


def _average_surplus(summary):
    keys, month_index = _recent_full_months(summary)
    if not keys:
        return None, ""
    nets = [
        float(month_index[k].get("income", 0) or 0) - float(month_index[k].get("expenses", 0) or 0)
        for k in keys
    ]
    span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
    return sum(nets) / len(nets), span


def _exec_goal_time(query_spec, summary, scope_label):
    try:
        goal = float(query_spec.period_key)
    except (TypeError, ValueError):
        return None
    surplus, span = _average_surplus(summary)
    if surplus is None:
        return None
    if surplus <= 0:
        reply = (
            f"At your recent pace ({span}) you spent more than you earned, so ${goal:.0f} "
            "wouldn't build up without cutting spending first."
        )
    else:
        months = goal / surplus
        reply = (
            f"Your income has beaten your spending by about ${surplus:.0f} a month ({span}). "
            f"Setting all of that aside, ${goal:.0f} takes about {months:.1f} months."
        )
        if query_spec.reason_mode == "how_much":
            reply += f" Spread over a year, it's about ${goal / 12:.0f} a month."
    return {
        "reply": reply,
        "insights": ["Surplus = income minus spending, averaged over recent full months."],
        "actions": ["Move a fixed amount to savings right after payday."],
        "missing_fields": [],
        "facts_used": ["month_index.income", "month_index.expenses"],
        "period_resolved": span,
    }


def _exec_extra_spend(query_spec, summary, scope_label):
    try:
        extra = float(query_spec.period_key)
    except (TypeError, ValueError):
        return None
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    target = query_spec.compare_to
    row = month_index.get(target)
    if not isinstance(row, dict):
        return None
    net = float(row.get("income", 0) or 0) - float(row.get("expenses", 0) or 0)
    after = net - extra
    sign = "+" if after >= 0 else "-"
    verdict = "you'd still be ahead for the month" if after >= 0 else "you'd be behind"
    return {
        "reply": (
            f"So far in {target} your income is ahead of spending by ${net:.0f}. Spending "
            f"${extra:.0f} more would leave {sign}${abs(after):.0f}, so {verdict}."
        ),
        "insights": ["Based on this month's income and spending so far."],
        "actions": ["Check the Budget tab if that category has a limit."],
        "missing_fields": [],
        "facts_used": ["month_index.income", "month_index.expenses"],
        "period_resolved": target,
    }


def _exec_week_compare(query_spec, summary, scope_label):
    days = summary.get("day_index_recent")
    if not isinstance(days, dict) or not days:
        return None
    today = date_cls.today()

    def total(start, end):
        out = 0.0
        for key, row in days.items():
            if isinstance(row, dict) and start <= key <= end:
                out += float(row.get("expenses", 0) or 0)
        return out

    if query_spec.reason_mode == "usual":
        # the last 7 days against a usual week (the recent monthly average x 12 / 52)
        recent, recent_index = _recent_full_months(summary)
        if not recent:
            return None
        monthly = sum(float(recent_index[k].get("expenses", 0) or 0) for k in recent) / len(recent)
        usual = monthly * 12 / 52
        week = total((today - timedelta(days=6)).isoformat(), today.isoformat())
        gap = week - usual
        if abs(gap) < 0.1 * usual:
            verdict = "That's about a normal week."
        else:
            verdict = (
                f"That's {'above' if gap > 0 else 'below'} a usual week, by about ${abs(gap):.0f}."
            )
        return {
            "reply": (
                f"Over the last 7 days, {scope_label} spent about ${week:.0f}. A usual week is "
                f"about ${usual:.0f} (from your ${monthly:.0f} monthly average, "
                f"{recent[-1]} to {recent[0]}). {verdict}"
            ),
            "insights": ["A usual week = the recent monthly average x 12 / 52."],
            "actions": ["Ask which days were biggest this week."],
            "missing_fields": [],
            "facts_used": ["day_index_recent.expenses", "month_index.expenses"],
            "period_resolved": "last 7 days",
        }
    if query_spec.reason_mode == "halves":
        # the first half of a month (days 1-15) against the rest of it
        month = query_spec.period_key
        year, num = int(month[:4]), int(month[5:7])
        last_day = calendar.monthrange(year, num)[1]
        first_start, first_end = f"{month}-01", f"{month}-15"
        second_start, second_end = f"{month}-16", f"{month}-{last_day:02d}"
        if first_start < min(days):
            return _pointer(
                f"I only get daily totals from {min(days)} on, so I can't split {month} in half.",
                "Ask about a later month.",
            )
        first = total(first_start, first_end)
        second = total(second_start, min(second_end, today.isoformat()))
        gap = first - second
        running = today.strftime("%Y-%m") == month
        if abs(gap) < 1:
            lead = "About the same. "
        elif running:
            lead = ""
        else:
            lead = f"The {'first' if gap > 0 else 'second'} half was higher. "
        note = f" ({month} isn't over yet.)" if running else ""
        return {
            "reply": (
                f"{lead}In {month}, {scope_label} spent about ${first:.0f} on days 1 to 15 and "
                f"about ${second:.0f} on days 16 to {last_day}.{note}"
            ),
            "insights": ["Halves are days 1-15 and 16 to the month's end, from daily totals."],
            "actions": ["Ask which day was biggest that month."],
            "missing_fields": [],
            "facts_used": ["day_index_recent.expenses"],
            "period_resolved": month,
        }
    if query_spec.reason_mode == "mtd":
        # "the same time last month": day 1 to today in both months
        this_start = today.replace(day=1)
        last_end_day = this_start - timedelta(days=1)
        last_start = last_end_day.replace(day=1)
        last_end = last_start.replace(day=min(today.day, last_end_day.day))
        if last_start.isoformat() < min(days):
            return None
        now = total(this_start.isoformat(), today.isoformat())
        before = total(last_start.isoformat(), last_end.isoformat())
        gap = now - before
        word = "more" if gap > 0 else "less"
        return {
            "reply": (
                f"Through day {today.day}, you've spent about ${now:.0f} in "
                f"{this_start.strftime('%Y-%m')} for {scope_label}, vs about ${before:.0f} by the "
                f"same day of {last_start.strftime('%Y-%m')}: ${abs(gap):.0f} {word}."
            ),
            "insights": ["Both months are counted from day 1 to the same day."],
            "actions": ["Ask whether this month is on pace for the month."],
            "missing_fields": [],
            "facts_used": ["day_index_recent.expenses"],
            "period_resolved": f"{this_start.strftime('%Y-%m')} vs {last_start.strftime('%Y-%m')}",
        }
    span = int(query_spec.period_key) if (query_spec.period_key or "").isdigit() else 7
    this_start = (today - timedelta(days=span - 1)).isoformat()
    last_start = (today - timedelta(days=2 * span - 1)).isoformat()
    last_end = (today - timedelta(days=span)).isoformat()
    if last_start < min(days):
        return _pointer(
            f"I only get daily totals from {min(days)} on, so I can't add up the {span} days "
            "before that.",
            "Ask about a shorter window.",
        )
    this_week = total(this_start, today.isoformat())
    last_week = total(last_start, last_end)
    gap = this_week - last_week
    word = "more" if gap > 0 else "less"
    when = "this week" if span == 7 else f"in the last {span} days"
    return {
        "reply": (
            f"Last {span} days: about ${this_week:.0f}; the {span} days before: about "
            f"${last_week:.0f} for {scope_label}. That's ${abs(gap):.0f} {word} {when}."
        ),
        "insights": ["Weeks are the last 7 days and the 7 days before them."],
        "actions": ["Ask which days were biggest this week."],
        "missing_fields": [],
        "facts_used": ["day_index_recent.expenses"],
        "period_resolved": "last 14 days",
    }


def _exec_threshold_check(query_spec, summary, scope_label):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    target = query_spec.period_key
    category = query_spec.category
    amount = _month_amount(month_index.get(target), category)
    try:
        limit = float(query_spec.compare_to)
    except (TypeError, ValueError):
        return None
    if amount is None:
        return None
    over = query_spec.reason_mode in {"over", "more than", "above", "at least"}
    subject = f"on {category} " if category else ""
    factor, progress = _month_scale(target)
    is_over = amount > limit
    answer = "Yes" if is_over == over else "No"
    gap = abs(amount - limit)
    side = "over" if is_over else "under"
    reply = (
        f"{answer}: you spent ${amount:.0f} {subject}in {target}, ${gap:.0f} {side} ${limit:.0f}."
    )
    if progress and not is_over:
        projected = amount * factor
        reply = (
            f"Not yet: you've spent ${amount:.0f} {subject}so far in {target} "
            f"({progress[0]} of {progress[1]} days). At this pace you'd reach about "
            f"${projected:.0f}, {'over' if projected > limit else 'still under'} ${limit:.0f}."
        )
    return {
        "reply": reply,
        "insights": ["Amount is read directly from validated month indexes."],
        "actions": ["Ask how this compares with your usual month."],
        "missing_fields": [],
        "facts_used": ["month_index.categories" if category else "month_index.expenses"],
        "period_resolved": target,
    }


def _exec_count_months(query_spec, summary, scope_label):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    try:
        limit = float(query_spec.compare_to)
    except (TypeError, ValueError):
        return None
    current = date_cls.today().strftime("%Y-%m")
    over = query_spec.reason_mode in {"over", "more than", "above"}
    period_key = query_spec.period_key or ""
    wanted = set(period_key.split(",")) if "," in period_key else None
    hits, total = [], 0
    for key in sorted(month_index):
        if key == current or (wanted and key not in wanted):
            continue
        row = month_index[key]
        if query_spec.category:
            amount = _month_amount(row, query_spec.category)
        elif query_spec.metric == "net":
            amount = float(row.get("income", 0) or 0) - float(row.get("expenses", 0) or 0)
        else:
            amount = float(row.get(query_spec.metric, 0) or 0)
        if amount is None:
            continue
        total += 1
        if (amount > limit) == over:
            hits.append(f"{key} (${amount:.0f})")
    word = "over" if over else "under"
    subject = f"{query_spec.category} spending" if query_spec.category else query_spec.metric
    if query_spec.metric == "net" and limit == 0:
        # "how many months did I save money"
        months = f"your {total} full months"
        listed = f": {', '.join(hits)}" if hits else ""
        return {
            "reply": (
                f"In {len(hits)} of {months} you earned more than you spent{listed}.".replace(
                    "($", "(+$"
                )
            ),
            "insights": ["Counted from validated monthly totals; the current month is left out."],
            "actions": ["Ask which month you saved the most."],
            "missing_fields": [],
            "facts_used": ["month_index.income", "month_index.expenses"],
            "period_resolved": "all months",
        }
    listed = f": {', '.join(hits)}" if hits else ""
    lead = ""
    if query_spec.period_type == "any":
        lead = "Yes. " if hits else "No. "
    elif query_spec.period_type == "every":
        lead = "Yes. " if total and len(hits) == total else "No. "
    months = f"your {total} full months"
    if wanted:
        ordered = sorted(wanted)
        months = f"the {total} full months from {ordered[0]} to {ordered[-1]}"
    return {
        "reply": f"{lead}{len(hits)} of {months} had {subject} {word} ${limit:.0f}{listed}.",
        "insights": ["Counted from validated monthly totals; the current month is left out."],
        "actions": ["Ask why one of those months was high."],
        "missing_fields": [],
        "facts_used": ["month_index"],
        "period_resolved": "all months",
    }


def _exec_percent_of(query_spec, summary, scope_label):
    try:
        pct = float(query_spec.period_key)
    except (TypeError, ValueError):
        return None
    keys, month_index = _recent_full_months(summary)
    if not keys:
        return None
    category = query_spec.category
    if category:
        values = [_month_amount(month_index[k], category) for k in keys]
    else:
        values = [float(month_index[k].get(query_spec.metric, 0) or 0) for k in keys]
    if any(v is None for v in values):
        return None
    usual = sum(values) / len(values)
    subject = f"{category} spending" if category else query_spec.metric
    span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
    return {
        "reply": (
            f"{pct:g}% of your usual monthly {subject} (about ${usual:.0f}, {span}) is about "
            f"${usual * pct / 100:.0f}."
        ),
        "insights": ["Usual = average of your recent full months."],
        "actions": ["Ask what cutting that amount would save in a year."],
        "missing_fields": [],
        "facts_used": ["month_index"],
        "period_resolved": span,
    }


def _exec_all_time(query_spec, summary, scope_label):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    if not month_index:
        return None
    keys = sorted(month_index)
    if query_spec.category:
        values = [_month_amount(month_index[k], query_spec.category) for k in keys]
        if any(v is None for v in values):
            return None
        total = sum(values)
        subject = f"{query_spec.category} spending"
    else:
        income = sum(float(month_index[k].get("income", 0) or 0) for k in keys)
        expenses = sum(float(month_index[k].get("expenses", 0) or 0) for k in keys)
        total = {"income": income, "net": income - expenses}.get(query_spec.metric, expenses)
        subject = {"income": "income", "net": "net cash flow"}.get(query_spec.metric, "spending")
    return {
        "reply": (
            f"Since your data starts ({keys[0]} to {keys[-1]}), total {subject} for "
            f"{scope_label} is about ${total:.0f}."
        ),
        "insights": ["Sum of every month the app has data for."],
        "actions": ["Ask for one year or month for detail."],
        "missing_fields": [],
        "facts_used": ["month_index"],
        "period_resolved": f"{keys[0]} to {keys[-1]}",
    }


def _exec_savings_lever(keys, month_index, scope_label):
    totals = {}
    for key in keys:
        cats = month_index[key].get("categories")
        if not isinstance(cats, dict):
            return None
        for name, amount in cats.items():
            if "transfer" in str(name).lower():
                continue
            totals[str(name)] = totals.get(str(name), 0.0) + float(amount or 0) / len(keys)
    ranked = sorted(totals.items(), key=lambda kv: -kv[1])
    spend = sum(float(month_index[k].get("expenses", 0) or 0) for k in keys) / len(keys)
    if spend > 0 and sum(totals.values()) < 0.2 * spend:
        return _pointer(
            f"Most of {scope_label}'s spending is transfers and payments, which aren't split by "
            "category, so I can't point to a category to cut. Pick Overall (All Accounts) in "
            "the Account scope menu above the chat to plan savings across everything.",
            "Switch the Account scope to Overall (All Accounts).",
        )
    if not ranked:
        return None
    name, usual = ranked[0]
    span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
    runner = ""
    if len(ranked) > 1:
        runner = f" The next biggest is {ranked[1][0]} at about ${ranked[1][1]:.0f}."
    return {
        "reply": (
            f"{name} is your biggest category at about ${usual:.0f} a month ({span}), so it's "
            f"where a cut saves the most: 20% less is about ${usual * 0.2:.0f} a month "
            f"(${usual * 0.2 * 12:.0f} a year).{runner}"
        ),
        "insights": ["Usual = average of your recent full months for each category."],
        "actions": [f"Set a {name} limit of about ${usual * 0.8:.0f} in the Budget tab."],
        "missing_fields": [],
        "facts_used": ["month_index.categories"],
        "period_resolved": span,
    }


def _exec_day_span(query_spec, summary, scope_label):
    days = summary.get("day_index_recent")
    if not isinstance(days, dict) or not days:
        return None
    start, end = (query_spec.period_key or ",").split(",")
    today = date_cls.today().isoformat()
    if start > today:
        return _pointer(
            f"{start} to {end} hasn't happened yet, so there's no spending for it.",
            "Ask about days that have already passed.",
        )
    end = min(end, today)  # "the third week of October" stops at today
    if start < min(days):
        return _pointer(
            f"I only get daily totals from {min(days)} on, so I can't add up {start} to {end}. "
            "Activity lists the transactions for those dates.",
            "Open Activity and filter to those dates.",
        )
    total = 0.0
    count = 0
    deposits = 0.0
    for key, row in days.items():
        if isinstance(row, dict) and start <= key <= end:
            total += float(row.get("expenses", 0) or 0)
            count += int(row.get("tx_count", 0) or 0)
            deposits += float(row.get("income", 0) or 0)
    if total < 0.5:
        # Days can hold only deposits or transfers in, which aren't spending.
        return _pointer(
            f"I don't see any spending for {scope_label} from {start} to {end}.",
            "Ask about a wider date range.",
        )
    if query_spec.category:
        return _pointer(
            f"Chat only has category totals by month, so I can't split {start} to {end} by "
            f"category. From {start} to {end}, {scope_label} spent about ${total:.0f} in total "
            f"across {count} transactions.",
            f"Search Activity for {query_spec.category} to see those days.",
        )
    shown = f"${total:.2f}" if total < 10 else f"${total:.0f}"
    return {
        "reply": (
            f"From {start} to {end}, you spent about {shown} for {scope_label} across "
            f"{count} transaction{'' if count == 1 else 's'}"
            f"{', counting deposits' if deposits >= 0.5 else ''}."
        ),
        "insights": ["Summed from the daily totals the app sends."],
        "actions": ["Ask which of those days was biggest."],
        "missing_fields": [],
        "facts_used": ["day_index_recent.expenses"],
        "period_resolved": f"{start} to {end}",
    }


def _exec_saving_target(query_spec, summary, scope_label):
    keys, month_index = _recent_full_months(summary)
    surplus, span = _average_surplus(summary)
    if not keys or surplus is None:
        return None
    if query_spec.reason_mode == "projection":
        target = query_spec.period_key
        current = _selected_month(summary)
        if not re.match(r"^20\d{2}-\d{2}$", target or "") or not current or target < current:
            return None
        row = (summary.get("month_index") or {}).get(current)
        if target == current and isinstance(row, dict):
            income = float(row.get("income", 0) or 0)
            spent = float(row.get("expenses", 0) or 0)
            factor, progress = _month_scale(current)
            pace = spent * factor
            kept = income - spent
            reply = (
                f"So far in {current} you've kept about {'-' if kept < 0 else ''}${abs(kept):.0f} "
                f"(income ${income:.0f} minus spending ${spent:.0f})."
            )
            if progress:
                end = income - pace
                reply += (
                    f" If spending keeps its pace (about ${pace:.0f} for the month) and no more "
                    f"income comes in, you'd end the month near "
                    f"{'-' if end < 0 else ''}${abs(end):.0f}."
                )
            return {
                "reply": reply,
                "insights": ["Projection assumes the rest of the month runs at today's pace."],
                "actions": ["Ask which category to cut to keep more."],
                "missing_fields": [],
                "facts_used": ["month_index.income", "month_index.expenses"],
                "period_resolved": current,
            }
        factor, progress = _month_scale(current)
        left_now = 1 - 1 / factor if progress else 0.0
        months = (int(target[:4]) - int(current[:4])) * 12 + int(target[5:]) - int(current[5:])
        months += left_now
        total = surplus * months
        caveat = _card_payments_caveat(summary, keys, month_index)
        if surplus > 0:
            reply = (
                f"At your recent pace (income beating spending by about ${surplus:.0f} a month, "
                f"{span}), you'd add about ${total:.0f} by the end of {target}."
            )
        else:
            reply = (
                f"At your recent pace you spend about ${-surplus:.0f} a month more than you earn "
                f"({span}), so by the end of {target} you'd be about ${-total:.0f} behind, not "
                "ahead."
            )
        return {
            "reply": f"{reply} That doesn't count money you've already saved, which chat can't "
            f"see.{caveat}",
            "insights": ["Surplus = income minus spending, averaged over recent full months."],
            "actions": ["Ask which category to cut to save more."],
            "missing_fields": [],
            "facts_used": ["month_index.income", "month_index.expenses"],
            "period_resolved": span,
        }
    if query_spec.reason_mode == "capacity":
        if surplus <= 0:
            reply = (
                f"Recently ({span}) you spent more than you earned, so there's no surplus to "
                "save yet without cutting spending."
            )
        else:
            reply = (
                f"Your income has beaten your spending by about ${surplus:.0f} a month ({span}), "
                "so that's roughly what you could save each month at your current pace."
            )
        return {
            "reply": reply,
            "insights": ["Surplus = income minus spending, averaged over recent full months."],
            "actions": ["Move a fixed amount to savings right after payday."],
            "missing_fields": [],
            "facts_used": ["month_index.income", "month_index.expenses"],
            "period_resolved": span,
        }
    if query_spec.period_type == "percent":
        pct = float(query_spec.period_key)
        income = sum(float(month_index[k].get("income", 0) or 0) for k in keys) / len(keys)
        monthly = income * pct / 100
        fits = "fits within" if monthly <= surplus else "is more than"
        lead = ""
        if query_spec.reason_mode == "rule_of_thumb":
            lead = "A common rule of thumb is to save about 20% of your income. "
        if surplus > 0:
            compare = f"That {fits} your average surplus of about ${surplus:.0f} a month."
        else:
            compare = (
                f"Recently you've spent about ${-surplus:.0f} a month more than you earned, so "
                "this would need spending cuts first."
            )
        reply = (
            f"{lead}{pct:g}% of your usual income (about ${income:.0f} a month, {span}) is about "
            f"${monthly:.0f} a month, ${monthly * 12:.0f} a year. {compare}"
        )
    else:
        goal = float(query_spec.period_key)
        today = date_cls.today()
        if query_spec.compare_to == "year_end":
            months_left = 12 - today.month + 1
            when = "by the end of the year"
        else:
            months_left = 12
            when = "in a year"
        needed = goal / months_left
        verdict = "doable" if needed <= surplus else "more than your usual surplus"
        if surplus > 0:
            pace = (
                f"Your income has beaten your spending by about ${surplus:.0f} a month "
                f"({span}), so that's {verdict}."
            )
        else:
            pace = (
                f"Recently ({span}) you've spent about ${-surplus:.0f} a month more than you "
                "earned, so it would need spending cuts first."
            )
        reply = (
            f"Saving ${goal:.0f} {when} means about ${needed:.0f} a month over {months_left} "
            f"months. {pace}"
        )
    return {
        "reply": reply,
        "insights": ["Surplus = income minus spending, averaged over recent full months."],
        "actions": ["Move that amount to savings right after payday."],
        "missing_fields": [],
        "facts_used": ["month_index.income", "month_index.expenses"],
        "period_resolved": span,
    }


def _exec_month_outlook(query_spec, summary, scope_label):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    target = query_spec.period_key
    row = month_index.get(target)
    if not isinstance(row, dict):
        return None
    income = float(row.get("income", 0) or 0)
    expenses = float(row.get("expenses", 0) or 0)
    factor, progress = _month_scale(target)
    projected = expenses * factor
    left = income - projected
    so_far = ""
    if progress:
        so_far = f" ({progress[0]} of {progress[1]} days in)"
    if left >= 0:
        verdict = f"you'd finish about ${left:.0f} ahead"
    else:
        verdict = f"you'd be about ${-left:.0f} short"
    net_now = income - expenses
    sign = "+" if net_now >= 0 else "-"
    if query_spec.compare_to:
        keep = float(query_spec.compare_to)
        room = net_now - keep
        pace_more = projected - expenses
        if room > 0:
            verdict = (
                f"To keep ${keep:.0f}, you could spend about ${room:.0f} more this month, "
                f"assuming no more income arrives. At your current pace you'd spend about "
                f"${pace_more:.0f} more."
            )
        else:
            verdict = (
                f"You're already ${-room:.0f} short of keeping ${keep:.0f} this month unless "
                "more income arrives."
            )
        return {
            "reply": (
                f"So far in {target}{so_far} you're at {sign}${abs(net_now):.0f} (income "
                f"${income:.0f}, spending ${expenses:.0f}). {verdict}"
            ),
            "insights": ["Room = income so far minus spending so far minus the amount to keep."],
            "actions": ["Ask which category is running above usual."],
            "missing_fields": [],
            "facts_used": ["month_index.income", "month_index.expenses"],
            "period_resolved": target,
        }
    return {
        "reply": (
            f"So far in {target}{so_far} you're at {sign}${abs(net_now):.0f} "
            f"(income ${income:.0f}, spending ${expenses:.0f}). Spending is on pace for about "
            f"${projected:.0f}, so "
            f"{verdict} by month end, assuming no more income arrives."
        ),
        "insights": ["Projection assumes spending continues at this month's pace."],
        "actions": ["Ask which category is running above usual."],
        "missing_fields": [],
        "facts_used": ["month_index.income", "month_index.expenses"],
        "period_resolved": target,
    }


def _exec_rate_math(query_spec, summary, scope_label):
    try:
        amount = float(query_spec.period_key)
    except (TypeError, ValueError):
        return None
    per = query_spec.period_type
    horizon = query_spec.compare_to or "year"
    per_year = {"day": 365, "week": 52, "month": 12}
    span = re.match(r"^(\d+) (months|years)$", horizon)
    if span:
        years = int(span.group(1)) / (12 if span.group(2) == "months" else 1)
        count = per_year.get(per, 0) * years
        horizon_text = horizon
    else:
        counts = {
            ("day", "year"): 365,
            ("week", "year"): 52,
            ("month", "year"): 12,
            ("day", "month"): 30,
            ("week", "month"): 52 / 12,
            ("month", "month"): 1,
        }
        count = counts.get((per, horizon))
        horizon_text = f"a {horizon}"
    if not count:
        return None
    total = amount * count
    if query_spec.category == "save":
        lead = f"Saving ${amount:.0f} every {per} adds up to about ${total:.0f} over {horizon_text}"
    else:
        lead = (
            f"Spending ${amount:.0f} less every {per} saves about ${total:.0f} over {horizon_text}"
        )
    return {
        "reply": f"{lead} (${amount:.0f} x {count:g} {per}s), before any interest.",
        "insights": ["Simple multiplication; no change in your other spending assumed."],
        "actions": ["Set that amount as a monthly target in the Budget tab."],
        "missing_fields": [],
        "facts_used": [],
        "period_resolved": horizon,
    }


_GLOSSARY = {
    "net_worth": (
        "Net worth is what your connected accounts hold minus what you owe on them (cards, "
        "loans). The Home tab shows it."
    ),
    "net_worth_negative": (
        "Net worth goes negative when balances owed on connected cards or loans are larger "
        "than the cash in your connected accounts. Chat can't see balances; the Home tab "
        "shows the figure."
    ),
    "cash_flow": (
        "Cash flow is money in minus money out for a period: income minus expenses. "
        "Positive means you kept money that month."
    ),
    "income_vs_cash_flow": (
        "Income is the money that came in. Cash flow is income minus expenses, so it shows "
        "what was left after spending."
    ),
    "fees_transfers": (
        "Fees & Transfers covers bank fees and money moved between accounts or to people "
        "(Zelle, Venmo, account transfers). Card payments aren't counted as spending."
    ),
    "savings_rate": (
        "Savings rate is the share of income you didn't spend: (income - expenses) / income."
    ),
    "budget": (
        "Each budget card compares a category's spending this month with the limit you set "
        "on the Budget tab, and projects where it will land by month end."
    ),
    "income": "Income is money coming into your connected accounts, excluding transfers.",
    "expenses": (
        "Expenses are purchases and bills from your connected accounts, excluding transfers "
        "between your own accounts and card payments."
    ),
    "other": "Other holds spending that didn't fit any of the app's categories.",
    "subscriptions": "Subscriptions are recurring charges such as streaming or software.",
}
_ACTION_REPLIES = {
    "budget": "I can't change budgets from chat. Use Edit Budget on the Budget tab.",
    "export": "I can't export data from chat.",
    "remind": "I can't set reminders.",
    "categorize": "I can't change a transaction's category from chat.",
    "delete": "I can't delete data from chat.",
    "chart": "Chat replies in text. The Flow tab has charts of your spending.",
    "other": "I can only answer questions about your data; I can't change anything.",
}


def _join_results(results):
    return {
        "reply": " ".join(r["reply"] for r in results),
        "insights": results[0].get("insights", []),
        "actions": results[0].get("actions", []),
        "missing_fields": [],
        "facts_used": sorted({f for r in results for f in r.get("facts_used", [])}),
        "period_resolved": results[0].get("period_resolved", ""),
    }


def _exec_amount_judgement(query_spec, summary, scope_label):
    """Put a stated amount next to the user's usual spending."""
    try:
        amount = float(query_spec.period_key)
    except (TypeError, ValueError):
        return None
    category = query_spec.category
    keys, month_index = _recent_full_months(summary)
    values = [_month_amount(month_index[k], category) for k in keys]
    if not values or any(v is None for v in values):
        return None
    usual = sum(values) / len(values)
    span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
    if usual <= 0 and category:
        return _pointer(
            f"You haven't spent anything on {category} for {scope_label} recently ({span}), so "
            f"${amount:.0f} a "
            f"{query_spec.period_type if query_spec.period_type in {'week', 'day'} else 'month'} "
            "would be new spending for this account.",
            f"Ask how much you spent on {category} this year.",
        )
    if usual <= 0:
        return None
    subject = f"{category} spending" if category else "total spending"
    span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
    if query_spec.period_type == "month":
        if amount > usual * 1.1:
            verdict = f"that's more than you usually spend (about ${usual:.0f} a month)"
        elif amount < usual * 0.9:
            verdict = f"that's less than you usually spend (about ${usual:.0f} a month)"
        else:
            verdict = f"that's about what you usually spend (about ${usual:.0f} a month)"
        what = f"on {category}" if category else "in total"
        reply = f"For you, ${amount:.0f} a month {what}: {verdict}."
    elif query_spec.period_type in {"week", "day"}:
        unit = query_spec.period_type
        usual_unit = usual * 12 / (52 if unit == "week" else 365)
        what = f"on {category}" if category else "in total"
        if amount > usual_unit * 1.1:
            verdict = "that's more than you usually spend"
        elif amount < usual_unit * 0.9:
            verdict = "that's less than you usually spend"
        else:
            verdict = "that's about what you usually spend"
        reply = (
            f"For you, ${amount:.0f} a {unit} {what}: {verdict} (about ${usual_unit:.0f} a {unit})."
        )
    else:
        share = amount / usual * 100
        reply = (
            f"${amount:.0f} is about {share:.0f}% of your usual monthly {subject} "
            f"(about ${usual:.0f}, {span})."
        )
    term = (query_spec.compare_to or "").strip()
    if term and category:
        reply = f"{term.title()} isn't tracked separately; it's part of {category}. {reply}"
    return {
        "reply": reply,
        "insights": [f"Usual = average of your full months {span}."],
        "actions": ["Ask whether this month is on pace compared with your usual."],
        "missing_fields": [],
        "facts_used": ["month_index.categories" if category else "month_index.expenses"],
        "period_resolved": span,
    }


def _exec_derived_metric(query_spec, summary, scope_label):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    target = query_spec.period_key
    row = month_index.get(target)
    mode = query_spec.reason_mode
    today = date_cls.today()
    running = target == today.strftime("%Y-%m")
    if mode == "savings_rate" and query_spec.period_type == "month_range":
        keys = [k for k in target.split(",") if k]
        row = _merged_row(month_index, keys)
        target = _span_label(month_index, keys)
        running = today.strftime("%Y-%m") in keys and target.endswith(today.strftime("%Y-%m"))
    if mode == "savings_rate" and query_spec.period_type == "year":
        rows = [r for k, r in month_index.items() if str(k).startswith(f"{target}-")]
        row = {
            "income": sum(float(r.get("income", 0) or 0) for r in rows if isinstance(r, dict)),
            "expenses": sum(float(r.get("expenses", 0) or 0) for r in rows if isinstance(r, dict)),
        }
        target = f"{target} so far" if rows else target
    if mode == "per_day" and query_spec.period_type == "year":
        row = {}  # the year path adds its months up below
    if mode in {"tx_count", "savings_rate", "per_day", "per_tx"} and not isinstance(row, dict):
        return None
    if mode == "per_tx":
        count = int(row.get("expense_tx_count", 0) or 0)
        expenses = float(row.get("expenses", 0) or 0)
        if count <= 0:
            return None
        reply = (
            f"In {target}{' so far' if running else ''}, your average spending transaction was "
            f"about ${expenses / count:.2f} (${expenses:.0f} over {count} purchases)."
        )
        if query_spec.category:
            reply = (
                f"Chat doesn't count transactions by category, so this covers all your spending, "
                f"not just {query_spec.category}. {reply}"
            )
        facts = ["month_index.expenses", "month_index.expense_tx_count"]
    elif mode == "tx_count":
        count = int(row.get("tx_count", 0) or 0)
        spend_count = int(row.get("expense_tx_count", 0) or 0)
        reply = (
            f"In {target}{' so far' if running else ''}, {scope_label} has {count} transactions, "
            f"{spend_count} of them spending."
        )
        facts = ["month_index.tx_count"]
    elif mode == "savings_rate":
        income = float(row.get("income", 0) or 0)
        expenses = float(row.get("expenses", 0) or 0)
        if income <= 0:
            reply = f"There's no recorded income in {target}, so there's no savings rate."
        else:
            rate = (income - expenses) / income * 100
            guide = ""
            if query_spec.compare_to == "good":
                if rate >= 20:
                    guide = (
                        "That's good: it beats the common rule of thumb of saving at least 20% "
                        "of income. "
                    )
                elif rate > 0:
                    guide = (
                        "It's on the low side: a common rule of thumb is to save at least 20% "
                        "of income. "
                    )
                else:
                    guide = (
                        "That's not good: a common rule of thumb is to save at least 20% of "
                        "income. "
                    )
            if rate >= 0:
                kept = f" and kept {rate:.0f}%"
            else:
                kept = (
                    f", about ${expenses - income:.0f} more than you earned, so nothing was saved"
                )
            reply = guide + (
                f"{_in_period(target)}, you spent {expenses / income * 100:.0f}% of your income{kept} "
                f"(income ${income:.0f}, expenses ${expenses:.0f})."
            )
        facts = ["month_index.income", "month_index.expenses"]
    elif mode == "per_day" and query_spec.period_type == "year":
        # "average spending per day this year": the year so far over its days with data
        keys = sorted(k for k in month_index if str(k).startswith(f"{query_spec.period_key}-"))
        if not keys:
            return None
        first = date_cls.fromisoformat(f"{keys[0]}-01")
        last = (
            today
            if keys[-1] == today.strftime("%Y-%m")
            else date_cls.fromisoformat(
                f"{keys[-1]}-{calendar.monthrange(*map(int, keys[-1].split('-')))[1]:02d}"
            )
        )
        days = (last - first).days + 1
        spent = sum(float(month_index[k].get("expenses", 0) or 0) for k in keys)
        reply = (
            f"In {query_spec.period_key} so far, that's about ${spent / days:.0f} a day "
            f"(${spent:.0f} over {days} days, from {keys[0]})."
        )
        facts = ["month_index.expenses"]
    elif mode == "per_day":
        days = today.day if running else calendar.monthrange(*map(int, target.split("-")))[1]
        category = (query_spec.category or "").strip()
        expenses = _month_amount(row, category) if category else float(row.get("expenses", 0) or 0)
        if expenses is None:
            return None
        on = f" on {category}" if category else ""
        reply = (
            f"In {target}, that's about ${expenses / days:.0f} a day{on} "
            f"(${expenses:.0f} over {days} days)."
        )
        facts = ["month_index.categories" if category else "month_index.expenses"]
    else:
        days = summary.get("day_index_recent")
        if not isinstance(days, dict) or not days:
            return None
        rows = [(k, v) for k, v in days.items() if isinstance(v, dict)]
        if mode == "no_spend_days":
            year, month = (int(x) for x in target.split("-"))
            last_day = today.day if running else calendar.monthrange(year, month)[1]
            spent_days = {
                key
                for key, value in rows
                if key.startswith(target) and float(value.get("expenses", 0) or 0) > 0
            }
            if not any(k.startswith(target) for k, _ in rows) and target < min(days):
                return None
            free = last_day - len(spent_days)
            return {
                "reply": (
                    f"In {target}{' so far' if running else ''}, {free} of {last_day} days had "
                    f"no spending."
                ),
                "insights": ["Counted from the daily totals the app sends."],
                "actions": ["Ask which day you spent the most."],
                "missing_fields": [],
                "facts_used": ["day_index_recent.expenses"],
                "period_resolved": target,
            }
        if mode == "weekday":
            names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
            buckets = {i: [] for i in range(7)}
            for key, value in rows:
                buckets[date_cls.fromisoformat(key).weekday()].append(
                    float(value.get("expenses", 0) or 0)
                )
            averages = {i: sum(v) / len(v) for i, v in buckets.items() if v}
            if not averages:
                return None
            best = max(averages, key=averages.get)
            reply = (
                f"On your recent days with spending, {names[best]} averages the most, about "
                f"${averages[best]:.0f} per day it has spending."
            )
            return {
                "reply": reply,
                "insights": ["Based on the daily totals the app sends (about the last 4 months)."],
                "actions": ["Ask about weekends versus weekdays."],
                "missing_fields": [],
                "facts_used": ["day_index_recent.expenses"],
                "period_resolved": "recent days",
            }
        if mode == "weeks":
            weeks = {}
            for key, value in rows:
                if key.startswith(target):
                    week = min((int(key[8:10]) - 1) // 7, 3)
                    weeks[week] = weeks.get(week, 0.0) + float(value.get("expenses", 0) or 0)
            if not weeks:
                return None
            last = calendar.monthrange(*map(int, target.split("-")))[1]
            end = today.day if running else last
            parts = []
            for week in range(0, (end - 1) // 7 + 1 if end < 22 else 4):
                first_day = week * 7 + 1
                last_day = min(last if week == 3 else first_day + 6, end)
                parts.append(f"days {first_day} to {last_day} ${weeks.get(week, 0.0):.0f}")
            reply = (
                f"In {target}{' so far' if running else ''}, {scope_label} spent: "
                f"{', '.join(parts)}."
            )
            return {
                "reply": reply,
                "insights": ["Weeks are days 1-7, 8-14, 15-21 and 22 to the month's end."],
                "actions": ["Ask which week was biggest."],
                "missing_fields": [],
                "facts_used": ["day_index_recent.expenses"],
                "period_resolved": target,
            }
        if mode in {"top_week", "low_week"}:
            weeks = {}
            for key, value in rows:
                if key.startswith(target):
                    week = min((int(key[8:10]) - 1) // 7, 3)  # days 22+ count as week 4
                    weeks[week] = weeks.get(week, 0.0) + float(value.get("expenses", 0) or 0)
            if not weeks:
                return None
            lowest = mode == "low_week"
            week, amount = (min if lowest else max)(weeks.items(), key=lambda kv: kv[1])
            first_day = week * 7 + 1
            last_day = (
                calendar.monthrange(*map(int, target.split("-")))[1] if week == 3 else first_day + 6
            )
            reply = (
                f"In {target}, your {'lowest' if lowest else 'biggest'} spending week was days "
                f"{first_day} to {last_day}, at about ${amount:.0f}."
            )
        elif mode == "top_day":
            in_month = [kv for kv in rows if kv[0].startswith(target)] or rows
            key, value = max(in_month, key=lambda kv: float(kv[1].get("expenses", 0) or 0))
            reply = (
                f"Your biggest spending day{' in ' + target if key.startswith(target) else ''} "
                f"was {key}, at about ${float(value.get('expenses', 0) or 0):.0f}."
            )
        elif query_spec.compare_to == "in_month":
            # "how much did I spend on weekends last month": that month's days
            in_month = [kv for kv in rows if kv[0].startswith(target)]
            if not in_month:
                return None
            weekend = sum(
                float(v.get("expenses", 0) or 0)
                for k, v in in_month
                if date_cls.fromisoformat(k).weekday() >= 5
            )
            weekday = sum(
                float(v.get("expenses", 0) or 0)
                for k, v in in_month
                if date_cls.fromisoformat(k).weekday() < 5
            )
            reply = (
                f"In {target}, {scope_label} spent about ${weekend:.0f} on weekends and about "
                f"${weekday:.0f} on weekdays."
            )
        else:
            weekend, weekday = [], []
            for key, value in rows:
                bucket = weekend if date_cls.fromisoformat(key).weekday() >= 5 else weekday
                bucket.append(float(value.get("expenses", 0) or 0))
            if not weekend and not weekday:
                return None
            if not weekend or not weekday:
                # One account can spend only on weekdays (or only on weekends).
                seen, none = ("weekday", "weekend") if weekday else ("weekend", "weekday")
                values = weekday or weekend
                reply = (
                    f"None of {scope_label}'s recent spending days fell on a {none}; a "
                    f"{seen} with spending averages about ${sum(values) / len(values):.0f}."
                )
            else:
                reply = (
                    f"Over your recent days with spending, a weekend day averages about "
                    f"${sum(weekend) / len(weekend):.0f} and a weekday about "
                    f"${sum(weekday) / len(weekday):.0f}."
                )
        facts = ["day_index_recent.expenses"]
    return {
        "reply": reply,
        "insights": ["Worked out directly from validated summary indexes."],
        "actions": ["Ask about a category or another month for comparison."],
        "missing_fields": [],
        "facts_used": facts,
        "period_resolved": target,
    }


def _pointer(reply, action, facts=()):
    return {
        "reply": reply,
        "insights": ["Chat sees monthly totals and your latest few transactions only."],
        "actions": [action],
        "missing_fields": [],
        "facts_used": list(facts),
        "period_resolved": "",
    }


def _exec_data_pointer(query_spec, summary, scope_label):
    mode = query_spec.reason_mode
    if mode == "other_person":
        who = (query_spec.category or "someone else").strip()
        who = "your " + who[3:] if who.startswith("my ") else who.title()
        return _pointer(
            f"I can only see the accounts connected to your own SmartSpend login, so I can't "
            f"tell you what {who} spent.",
            "Ask about your own spending, for example: How much did I spend last month?",
        )
    if mode.startswith("define:"):
        meaning = _GLOSSARY.get(mode.split(":", 1)[1])
        if not meaning:
            return None
        return _pointer(meaning, "Ask how much you spent or earned this month to see the numbers.")
    if mode.startswith("action:"):
        return _pointer(
            _ACTION_REPLIES.get(mode.split(":", 1)[1], _ACTION_REPLIES["other"]),
            "Ask me a question about your spending instead.",
        )
    if mode == "peers":
        keys, month_index = _recent_full_months(summary)
        extra = ""
        category = query_spec.category
        if keys:
            if category:
                avg = sum(_month_amount(month_index[k], category) or 0.0 for k in keys) / len(keys)
            else:
                avg = sum(float(month_index[k].get("expenses", 0) or 0) for k in keys) / len(keys)
            what = f"{category} average" if category else "average"
            if avg >= 1:
                extra = (
                    f" For reference, your own {what} is about ${avg:.0f} a month "
                    f"({keys[-1]} to {keys[0]})."
                )
        return _pointer(
            "I can't compare you with other people; I only see your own accounts." + extra,
            "Ask whether this month is above or below your own average.",
        )
    if mode == "about":
        return _pointer(
            "I'm SmartSpend's assistant. I answer questions about your own spending and "
            "income from the accounts you've connected.",
            "Ask: How much did I spend this month?",
        )
    if mode == "products":
        return _pointer(
            "I can't recommend specific financial products. I can show what you spend and "
            "where, which can help you compare options yourself.",
            "Ask which category you spend the most on.",
        )
    if mode == "capabilities":
        return _pointer(
            "I answer questions about your own spending and income: totals for a day, month "
            "or year, categories, comparisons between months, trends and averages, savings "
            "what-ifs and goals, and your latest transactions. Try: How much did I spend on "
            "food last month?",
            "Ask about a month, a category or a savings goal.",
        )
    if mode == "add_bank":
        return _pointer(
            "Use Add Bank on the Home tab to connect another account.",
            "Open Home and tap Add Bank.",
        )
    if mode == "privacy":
        return _pointer(
            "To answer, the app sends a summary of your own accounts (monthly and category "
            "totals and your latest few transactions) to its server, and some questions are "
            "passed to an AI model. Chat never sees bank logins or account numbers. For how "
            "data is stored, ask the app's team.",
            "Ask about your spending any time.",
        )
    if mode == "approx_cut":
        thing = (query_spec.category or "that").strip()
        parent = query_spec.compare_to
        month_index = (
            summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
        )
        row = month_index.get(query_spec.period_key)
        amount = _month_amount(row, parent) if parent and isinstance(row, dict) else None
        where = "it's inside a broader category"
        if amount is not None:
            where = (
                f"it's part of {parent}, which is about ${amount:.0f} in {query_spec.period_key}"
            )
        return _pointer(
            f"{thing.title()} isn't tracked separately ({where}), so I can't price cutting it. "
            f"Search Activity for {thing} to see what you spend on it.",
            f"Search Activity for {thing}.",
        )
    if mode == "statement":
        return _pointer(
            "Noted. Ask me something about your money, for example: How much did I spend "
            "this month?",
            "Ask about a month, a category or your income.",
        )
    if mode == "absent_category":
        name = query_spec.category or "that category"
        reply = f"I don't see any {name} spending for {scope_label} in your data."
        if summary.get("scope") == "single_account":
            reply += (
                " If you pay for it from another account, pick that account or Overall (All "
                "Accounts) in the Account scope menu above the chat."
            )
        return _pointer(reply, "Ask about a category this account spends on.")
    if mode == "card_income":
        month = query_spec.period_key
        month_index = summary.get("month_index") or {}
        # A year sums its months; a month is one row.
        rows = [r for k, r in month_index.items() if str(k).startswith(f"{month}-")]
        if "," in month:
            keys = sorted(month.split(","))
            rows = [month_index.get(k) for k in keys]
            month = f"{keys[0]} to {keys[-1]}"
        elif len(month) != 4:
            rows = [month_index.get(month)]
        rows = [r for r in rows if isinstance(r, dict)]
        lead = (
            f"{scope_label} is a credit card, so the money coming into it is card payments and "
            "refunds, not income."
        )
        if rows and all("card_payments_in" in r for r in rows):
            payments = sum(float(r.get("card_payments_in", 0) or 0) for r in rows)
            other = sum(float(r.get("income", 0) or 0) for r in rows)
            if payments >= 1:
                credits = f" and ${other:.0f} in refunds and credits" if other >= 1 else ""
                lead = (
                    f"Money into {scope_label} in {month} was about ${payments + other:.0f}: "
                    f"${payments:.0f} in card payments{credits}. That's the card being paid off, "
                    "not income."
                )
            elif other >= 1:
                lead = (
                    f"Money into {scope_label} in {month} was about ${other:.0f} in refunds and "
                    "credits. On a credit card that isn't income."
                )
        return _pointer(
            f"{lead} For income, savings or what you can afford, pick Overall (All Accounts) or "
            "your bank account in the Account scope menu above the chat.",
            "Ask about this card's spending, or switch the account scope.",
        )
    if mode == "category_week":
        category = query_spec.category
        windows = (
            summary.get("windows_rolling")
            if isinstance(summary.get("windows_rolling"), dict)
            else {}
        )
        week = float((windows.get("last_7d") or {}).get("expenses", 0) or 0)
        span = 7
        if (query_spec.compare_to or "").isdigit():
            # "the past 2 weeks": the daily totals for those days
            span = int(query_spec.compare_to)
            days = (
                summary.get("day_index_recent")
                if isinstance(summary.get("day_index_recent"), dict)
                else {}
            )
            start = (date_cls.today() - timedelta(days=span - 1)).isoformat()
            week = sum(
                float(r.get("expenses", 0) or 0)
                for k, r in days.items()
                if isinstance(r, dict) and k >= start
            )
        row = (summary.get("month_index") or {}).get(query_spec.period_key)
        month_amount = _month_amount(row, category) if isinstance(row, dict) else None
        parts = [
            f"Chat only has category totals by month, so I can't split the last {span} days by "
            f"category. Over the last {span} days, {scope_label} spent about ${week:.0f} in total"
        ]
        if not category:
            # "what did I spend the most on last week": the month's leader instead
            cats = row.get("categories") if isinstance(row, dict) else None
            if isinstance(cats, dict) and cats:
                name, amount = max(cats.items(), key=lambda kv: float(kv[1] or 0))
                parts.append(
                    f", and your biggest category in {query_spec.period_key} so far is {name} at "
                    f"about ${float(amount or 0):.0f}"
                )
            return _pointer("".join(parts) + ".", "Search Activity to see this week's charges.")
        if month_amount is not None and month_amount >= 1:
            parts.append(
                f", and {category} in {query_spec.period_key} so far is about ${month_amount:.0f}"
            )
        return _pointer(
            "".join(parts) + ".",
            f"Search Activity for {category} to see this week's charges.",
        )
    if mode == "refunds":
        row = (summary.get("month_index") or {}).get(query_spec.period_key)
        if credit_card_scope(summary) and isinstance(row, dict) and "card_payments_in" in row:
            credits = float(row.get("income", 0) or 0)
            if credits < 0.5:
                return _pointer(
                    f"I don't see any refunds or credits on {scope_label} in "
                    f"{query_spec.period_key}.",
                    "Search Activity for refund to check older ones.",
                )
            return _pointer(
                f"In {query_spec.period_key}, refunds and credits on {scope_label} came to about "
                f"${credits:.0f}.",
                "Search Activity for refund to see each one.",
            )
        return _pointer(
            "Chat doesn't get refunds as a separate total; they're counted in income. Search "
            "Activity for refund to see each one.",
            "Search Activity for refund.",
        )
    if mode == "injection":
        return _pointer(
            "I can't change how I work or share my setup. I can answer questions about your own "
            "spending and income, for example: How much did I spend this month?",
            "Ask about your spending, income or categories.",
        )
    if mode == "card_payments":
        period = query_spec.period_key
        month_index = summary.get("month_index") or {}
        if query_spec.period_type == "year":
            rows = [r for k, r in month_index.items() if str(k).startswith(f"{period}-")]
        else:
            rows = [month_index.get(period)]
        rows = [r for r in rows if isinstance(r, dict)]
        card = credit_card_scope(summary)
        key = "card_payments_in" if card else "card_payments_out"
        if not rows or not all(key in r for r in rows):
            return _pointer(
                "This version of the app doesn't send credit card payment totals to chat. "
                "Search Activity for 'payment' to see them.",
                "Search Activity for payment.",
            )
        paid = sum(float(r.get(key, 0) or 0) for r in rows)
        if paid < 1:
            reply = f"I don't see any credit card payments for {scope_label} in {period}."
        elif card:
            reply = f"In {period}, {scope_label} received about ${paid:.0f} in payments."
        else:
            reply = f"In {period}, {scope_label} paid about ${paid:.0f} toward credit cards."
        return _pointer(
            f"{reply} Card payments aren't counted as income or spending; the purchases on the "
            "card count as spending instead.",
            "Ask how much you spent on the card.",
        )
    if mode == "trip":
        event = (query_spec.category or "trip").strip()
        if event in {"trip", "vacation", "holiday", "holidays"}:
            what = "a trip"
        elif event in {"gift", "gifts", "date night"}:
            what = event if event.startswith("gift") else "date nights"
        elif event in {"christmas", "thanksgiving", "black friday", "halloween", "easter"}:
            what = event.title()
        elif event in {"new year s", "new years"}:
            what = "New Year's"
        elif event in {"valentine s day", "valentines day"}:
            what = "Valentine's Day"
        elif event == "spring break":
            what = "spring break"
        elif event == "moving":
            what = "your move"
        else:
            what = f"your {event}"
        return _pointer(
            f"I can't tell which charges were for {what}. If you know the dates, ask for that "
            "range, for example: How much did I spend from Aug 1 to Aug 15?",
            "Ask for the date range.",
        )
    if mode == "same_category":
        words = [w for w in (query_spec.compare_to or "").split("|") if w]
        category = query_spec.category
        row = (summary.get("month_index") or {}).get(query_spec.period_key)
        amount = _month_amount(row, category) if isinstance(row, dict) else None
        both = " and ".join(words) if words else "Those"
        reply = f"{both[:1].upper()}{both[1:]} both count as {category} in your data, so I can't split them."
        if amount:
            reply += f" {category} spending was about ${amount:.0f} in {query_spec.period_key}."
        else:
            reply += f" I don't see any {category} spending for {scope_label} in {query_spec.period_key}."
        return _pointer(reply, "Search Activity for each to compare the charges.")
    if mode == "forecast_week":
        keys, month_index = _recent_full_months(summary)
        if not keys:
            return None
        avg = sum(float(month_index[k].get("expenses", 0) or 0) for k in keys) / len(keys)
        span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
        return _pointer(
            f"Next week hasn't happened yet. You usually spend about ${avg * 12 / 52:.0f} a week "
            f"for {scope_label} ({span}), so a similar week would land near that.",
            "Ask how this month is pacing against your usual.",
        )
    if mode == "category_count":
        row = (summary.get("month_index") or {}).get(query_spec.period_key)
        category = query_spec.category
        extra = ""
        if isinstance(row, dict):
            amount = _month_amount(row, category)
            count = int(row.get("expense_tx_count", 0) or 0)
            if amount:
                extra = (
                    f" In {query_spec.period_key} you had {count} spending transactions in total, "
                    f"and {category} spending came to about ${amount:.0f}."
                )
        return _pointer(
            f"Chat doesn't count transactions per category, so I can't say how many were "
            f"{category}.{extra}",
            f"Search Activity for {category} to count them.",
        )
    if mode == "find_purchase":
        thing = (query_spec.category or "it").strip() or "it"
        return _pointer(
            f"I can't search all your transactions from chat. Search Activity for {thing} "
            "to find the latest one.",
            f"Search Activity for {thing}.",
        )
    if mode == "hello":
        return _pointer(
            "Hi! Ask me about your spending, income or categories, for example: "
            "How much did I spend this month?",
            "Try: What's my top category this month?",
        )
    if mode == "thanks":
        return _pointer("You're welcome. Ask anytime.", "Ask another question about your money.")
    if mode == "bye":
        return _pointer("Bye! Your numbers will be here when you're back.", "Come back anytime.")
    if mode == "move_money":
        return _pointer(
            "I can't move money, approve transfers or make payments. I only read your "
            "spending data to answer questions.",
            "Use your bank's own app for transfers and payments.",
        )
    if mode == "future_period":
        return _pointer(
            f"{query_spec.period_key} hasn't happened yet, so there's no spending for it.",
            "Ask how much you might spend next month for an estimate.",
        )
    if mode == "interest":
        recent = summary.get("recent_transactions")
        for item in recent if isinstance(recent, list) else []:
            name = str(item.get("name", "") or "") if isinstance(item, dict) else ""
            if "interest" in name.lower() and float(item.get("amount", 0) or 0):
                return _pointer(
                    f"Your latest interest charge was ${abs(float(item['amount'])):.2f} on "
                    f"{item.get('date', '')} ({name}). Chat can't total interest over time.",
                    "Search Activity for interest to see every charge.",
                )
        return _pointer(
            "Chat doesn't track interest separately, and I don't see an interest charge in "
            "your latest transactions. Interest your card charges or your bank pays shows up "
            "in Activity as its own transaction.",
            "Search Activity for interest.",
        )
    if mode == "cancel":
        return _pointer(
            "I can't cancel subscriptions or change anything in your accounts; I only read your "
            "spending. Cancel it with the company itself, and the Subs tab shows what each "
            "recurring charge costs.",
            "Open the Subs tab to review your recurring charges.",
        )
    if mode == "credit_score":
        return _pointer(
            "SmartSpend doesn't get your credit score, so I can't tell you what it is. Your "
            "card issuer's app or a credit bureau can show it.",
            "Ask about your spending or income instead.",
        )
    if mode == "taxes":
        return _pointer(
            "I can't total the tax you paid: tax taken out of your paycheck never shows up as a "
            "transaction, and your data has no tax category. Your pay stubs or tax forms have "
            "that number.",
            "If you paid tax directly, search Activity for IRS or your state's tax agency.",
        )
    if mode == "payer":
        return _pointer(
            "I can't tell who a payment came from. Money people send you shows up as income "
            "from the app or bank it came through, not under their name.",
            "Search Activity for their name or the app you used, like Venmo or Zelle.",
        )
    if mode == "balance":
        return _pointer(
            "Chat doesn't get your account balances. The Home tab shows your net worth "
            "across connected accounts.",
            "Open Home to see your net worth.",
        )
    if mode == "investing":
        keys, month_index = _recent_full_months(summary)
        nets = [
            float(month_index[k].get("income", 0) or 0)
            - float(month_index[k].get("expenses", 0) or 0)
            for k in keys
        ]
        extra = ""
        if credit_card_scope(summary):
            nets = []  # a card's money in is payments, not income
        if nets:
            avg = sum(nets) / len(nets)
            extra = (
                f" What I can tell you: over {keys[-1]} to {keys[0]} your income exceeded "
                f"spending by about ${avg:.0f} a month on average."
                if avg > 0
                else f" Over {keys[-1]} to {keys[0]} you spent more than you earned on average."
            )
        return _pointer(
            "I can't give investment advice; I only work with your spending and income." + extra,
            "Ask how much you could set aside each month, or for tips to cut spending.",
            ("month_index.income", "month_index.expenses") if nets else (),
        )
    if mode == "unclear":
        return _pointer(
            "I didn't catch that. Try something like: How much did I spend this month?",
            "Ask about spending, income, a category or a month.",
        )
    if mode == "forecast_year":
        keys, month_index = _recent_full_months(summary)
        if not keys:
            return None
        current = _selected_month(summary)
        year = current[:4]
        avg = sum(float(month_index[k].get("expenses", 0) or 0) for k in keys) / len(keys)
        so_far = sum(
            float(row.get("expenses", 0) or 0)
            for k, row in (summary.get("month_index") or {}).items()
            if str(k).startswith(f"{year}-") and isinstance(row, dict)
        )
        factor, progress = _month_scale(current)
        left = 12 - int(current[5:]) + ((1 - 1 / factor) if progress else 0.0)
        rest = avg * left
        span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
        return _pointer(
            f"In {year} so far, {scope_label} has spent about ${so_far:.0f}. At your recent pace "
            f"(about ${avg:.0f} a month, {span}), the rest of the year adds about ${rest:.0f}, "
            f"so {year} would end near ${so_far + rest:.0f}. That's an estimate, not a forecast "
            "of specific bills.",
            "Ask how this month is pacing against your usual.",
            ("month_index.expenses",),
        )
    if mode == "top_payee":
        row = (summary.get("month_index") or {}).get(_selected_month(summary))
        top = row.get("top_category") if isinstance(row, dict) else None
        extra = ""
        if isinstance(top, dict) and top.get("name"):
            extra = (
                f" Your biggest category this month is {top['name']} at about "
                f"${float(top.get('amount', 0) or 0):.0f}."
            )
        return _pointer(
            "Chat sees your spending by category, not totals by who you paid, so I can't rank "
            f"merchants.{extra}",
            "Open Activity and search a merchant's name to see what you paid them.",
        )
    if mode == "no_such_month":
        return _pointer(
            "There are only 12 months, so I'm not sure which one you mean. Try a month name, "
            "for example: What did I spend in March?",
            "Ask about a month by name.",
        )
    if mode == "forecast" and query_spec.compare_to == "income":
        if credit_card_scope(summary):
            return _exec_data_pointer(
                dataclasses.replace(query_spec, reason_mode="card_income", period_key=""),
                summary,
                scope_label,
            )
        keys, month_index = _recent_full_months(summary)
        if not keys:
            return None
        values = [float(month_index[k].get("income", 0) or 0) for k in keys]
        avg = sum(values) / len(values)
        return _pointer(
            f"I can't predict next month's income, but your last {len(values)} full months "
            f"({keys[-1]} to {keys[0]}) brought in about ${avg:.0f} a month on average "
            f"(from ${min(values):.0f} to ${max(values):.0f}).",
            "Ask how your income compares month to month.",
            ("month_index.income",),
        )
    if mode == "forecast":
        keys, month_index = _recent_full_months(summary)
        category = query_spec.category
        if category:
            values = [_month_amount(month_index[k], category) or 0.0 for k in keys]
        else:
            values = [float(month_index[k].get("expenses", 0) or 0) for k in keys]
        if not values:
            return None
        avg = sum(values) / len(values)
        if category and avg < 1:
            return _pointer(
                f"I don't see any {category} spending for {scope_label} recently, so there's "
                "nothing to estimate from.",
                f"Ask how much you spent on {category} this year.",
            )
        what = f"{category} spending" if category else "spending"
        return _pointer(
            f"I can't predict next month exactly, but your last {len(values)} full months "
            f"({keys[-1]} to {keys[0]}) averaged about ${avg:.0f} in {what}, so a similar "
            "month would land near that.",
            "Set a monthly target below that average in the Budget tab.",
            ("month_index.expenses",),
        )
    if mode == "invalid_date":
        return _pointer(
            f"{query_spec.category} isn't a real date. Try a valid day, for example 9/30.",
            "Ask about a valid date or a whole month.",
        )
    if mode == "biggest_purchase":
        category = (query_spec.category or "").strip()
        recent = summary.get("recent_transactions")
        rows = [
            item
            for item in (recent if isinstance(recent, list) else [])
            if isinstance(item, dict)
            and float(item.get("amount", 0) or 0) > 0
            and (not category or str(item.get("category", "")).lower() == category.lower())
        ]
        hint = ""
        if query_spec.period_key:
            rows = [r for r in rows if str(r.get("date", "")).startswith(query_spec.period_key)]
        if rows:
            top = max(rows, key=lambda item: float(item.get("amount", 0) or 0))
            hint = (
                f" Among your latest transactions, the largest{' ' + category if category else ''}"
                f" one is {top.get('name', '')} at ${float(top.get('amount', 0) or 0):.2f} "
                f"({top.get('date', '')})."
            )
        top_line = ""
        month = query_spec.period_key or _selected_month(summary)
        row = (summary.get("month_index") or {}).get(month) if month else None
        if month and len(month) == 4:
            # "my biggest expense this year": the year's category totals
            totals = {}
            for key, item in (summary.get("month_index") or {}).items():
                cats_in = item.get("categories") if isinstance(item, dict) else None
                if str(key).startswith(f"{month}-") and isinstance(cats_in, dict):
                    for name, amount in cats_in.items():
                        totals[name] = totals.get(name, 0.0) + float(amount or 0)
            row = {"categories": totals} if totals else None
        top = row.get("top_category") if isinstance(row, dict) else None
        cats = row.get("categories") if isinstance(row, dict) else None
        if not (isinstance(top, dict) and top.get("name")) and isinstance(cats, dict) and cats:
            name, amount = max(cats.items(), key=lambda kv: float(kv[1] or 0))
            top = {"name": name, "amount": amount}
        if not category and query_spec.compare_to == "several" and isinstance(cats, dict) and cats:
            ranked = sorted(cats.items(), key=lambda kv: -float(kv[1] or 0))[:3]
            listed = ", ".join(f"{name} ${float(amount or 0):.0f}" for name, amount in ranked)
            top_line = f"Your biggest spending categories in {month} are {listed}. "
        elif not category and isinstance(top, dict) and top.get("name"):
            top_line = (
                f"Your biggest spending category in {month} is {top['name']} at about "
                f"${float(top.get('amount', 0) or 0):.0f}. "
            )
        return _pointer(
            f"{top_line}I can't see every transaction from chat, so I can't pick your biggest "
            f"single purchase reliably.{hint} Activity lists every transaction for the month.",
            "Open Activity and pick the month to scan its largest charges.",
        )
    if mode == "merchant":
        name = (query_spec.category or "").strip()
        recent = summary.get("recent_transactions")
        for item in recent if isinstance(recent, list) else []:
            if not isinstance(item, dict):
                continue
            merchant = str(item.get("name", "") or "").strip()
            amount = float(item.get("amount", 0) or 0)
            if amount != 0 and name.lower() in merchant.lower():
                return _pointer(
                    f"Your latest {merchant} charge was ${abs(amount):.2f} on "
                    f"{item.get('date', '')}. "
                    "I can't total every charge from one merchant from chat.",
                    f"Search Activity for {merchant} to see every charge.",
                    ("recent_transactions",),
                )
        label = re.sub(r" S\b", "'s", name.title())
        label = re.sub(r"\bMc([a-z])", lambda m: "Mc" + m.group(1).upper(), label)
        if name.lower().startswith("my "):
            # "my dog", "my gym membership": a thing of theirs, not a merchant name
            return _pointer(
                f"I can't tell which charges were for your {name[3:]}. Search Activity for the "
                "store or service you paid to see them.",
                "Search Activity for the store or service.",
            )
        category = category_named(name, summary)
        under = f" It would count under {category}." if category else ""
        current = _selected_month(summary)
        row = (summary.get("month_index") or {}).get(current)
        amount = _month_amount(row, category) if category and isinstance(row, dict) else None
        if amount:
            under = (
                f" It would count under {category}; {category} spending was about "
                f"${amount:.0f} in {current}."
            )
        return _pointer(
            f"I don't see {label} in your latest transactions, and chat can't search older ones."
            f"{under}",
            f"Search Activity for {label} to see every charge.",
        )
    if mode == "payday":
        return _pointer(
            "Chat can't tell which deposit is your paycheck, so it can't split spending around "
            "payday. Ask about dates instead, like how much you spent from Oct 1 to Oct 14.",
            "Ask about a date range.",
        )
    if mode == "subscriptions":
        return _pointer(
            "Chat doesn't get your subscription list. The Subs tab shows each recurring "
            "charge and how often it bills.",
            "Open the Subs tab to review your recurring charges.",
        )
    if mode == "budget_status":
        answer = _budget_status(query_spec, summary)
        if answer is not None:
            return answer
        return _pointer(
            "Chat doesn't get your budget limits yet. The Budget tab shows each category's "
            "spending against its limit and its month-end pace.",
            "Open the Budget tab to see which categories are near or over their limit.",
        )
    return None


def _budget_vs_usual(items, asked, month, summary, answer):
    """"is my food budget realistic?": each limit against the average of the recent full
    months' spending in that category."""
    keys, month_index = _recent_full_months(summary)
    if not keys:
        return None
    chosen = [i for i in items if not asked or i["category"].lower() == asked.lower()]
    if not chosen:
        return answer(
            f"You don't have a budget limit for {asked} in {month}.",
            f"Set a {asked} limit in the Budget tab.",
        )
    lines = []
    for item in chosen:
        values = [
            float(((month_index.get(k) or {}).get("categories") or {}).get(item["category"], 0) or 0)
            for k in keys
        ]
        usual = sum(values) / len(values)
        limit = float(item["limit"])
        if usual <= 0:
            verdict = "chat's monthly totals have no recent spending to compare it with"
        elif limit < usual * 0.8:
            verdict = f"well below your usual ${usual:.0f} a month, so it's hard to keep"
        elif limit > usual * 1.25:
            verdict = f"well above your usual ${usual:.0f} a month, so you could lower it"
        else:
            verdict = f"close to your usual ${usual:.0f} a month"
        lines.append(f"{item['category']} ${limit:.0f}: {verdict}")
    span = f"{keys[-1]} to {keys[0]}" if len(keys) > 1 else keys[0]
    return {
        **answer(
            "; ".join(lines) + ".",
            "Adjust a limit in the Budget tab if it's far from what you usually spend.",
        ),
        "insights": [f"Usual = average spending per category over {span}."],
    }


def _budget_status(query_spec, summary):
    """Budget asks answered from the limits the app sends for its selected month:
    one category's limit and what's left, or which categories are over or on pace to go
    over. None when the app sent no budget block (older app versions)."""
    budgets = summary.get("budgets") if isinstance(summary, dict) else None
    if not isinstance(budgets, dict) or not isinstance(budgets.get("items"), list):
        return None
    month = budgets.get("month") or _selected_month(summary)
    items = budgets["items"]
    factor, progress = _month_scale(month)

    def answer(reply, action):
        return {
            "reply": reply,
            "insights": [f"Limits and spending are the Budget tab's figures for {month}."],
            "actions": [action],
            "missing_fields": [],
            "facts_used": ["budgets"],
            "period_resolved": month,
        }

    if query_spec.period_key and query_spec.period_key != month:
        return answer(
            f"Chat only gets the budgets for the month picked in the app, {month}. Pick "
            f"{query_spec.period_key} in the Month menu, then ask again.",
            "Pick that month in the Month menu.",
        )
    if not items:
        return answer(
            f"You haven't set any budget limits for {month}.",
            "Set a limit for a category in the Budget tab.",
        )

    def pace(item):
        return float(item["spent"]) * factor if progress else float(item["spent"])

    asked = (query_spec.category or "").split(",")[0]
    if query_spec.compare_to == "realistic":
        return _budget_vs_usual(items, asked, month, summary, answer)
    if asked:
        item = next((i for i in items if i["category"].lower() == asked.lower()), None)
        if item is None:
            return answer(
                f"You don't have a budget limit for {asked} in {month}.",
                f"Set a {asked} limit in the Budget tab.",
            )
        spent, limit = float(item["spent"]), float(item["limit"])
        left = limit - spent
        state = f"have ${left:.2f} left" if left >= 0 else f"are ${-left:.2f} over"
        reply = (
            f"For {month}, your {item['category']} budget is ${limit:.2f}: you've spent "
            f"${spent:.2f}, so you {state}."
        )
        if progress and left >= 0 and pace(item) > limit:
            reply += (
                f" At this pace you'd reach about ${pace(item):.0f} by month end, over the limit."
            )
        return answer(reply, f"Open the Budget tab for {item['category']}'s transactions.")

    if query_spec.compare_to == "share":
        spent = sum(float(i["spent"]) for i in items)
        limit = sum(float(i["limit"]) for i in items)
        return answer(
            f"In {month} you've used ${spent:.0f} of ${limit:.0f} across your budgets "
            f"({spent / limit * 100:.0f}%).",
            "Ask how much is left of one category's budget.",
        )

    over = [i for i in items if float(i["spent"]) > float(i["limit"])]
    heading = [i for i in items if progress and i not in over and pace(i) > float(i["limit"])]
    parts = []
    if over:
        parts.append(
            "Over budget: "
            + ", ".join(
                f"{i['category']} (${float(i['spent']):.0f} of ${float(i['limit']):.0f})"
                for i in over
            )
            + "."
        )
    if heading:
        parts.append(
            "On pace to go over: "
            + ", ".join(
                f"{i['category']} (${float(i['spent']):.0f} of ${float(i['limit']):.0f}, "
                f"on pace for ${pace(i):.0f})"
                for i in heading
            )
            + "."
        )
    if not parts:
        return answer(
            f"No. In {month}, every category with a budget is within its limit.",
            "Ask how much is left of a category's budget.",
        )
    within = len(items) - len(over) - len(heading)
    tail = ""
    if within:
        tail = (
            " The other category with a budget is within its limit."
            if within == 1
            else f" The other {within} categories with a budget are within their limits."
        )
    lead = "Yes. " if over and query_spec.compare_to == "yes_no" else ""
    return answer(
        f"{lead}For {month}: " + " ".join(parts) + tail, "Open the Budget tab to adjust a limit."
    )


def _earn_vs_spend_verdict(query_spec, net):
    """Yes or no for "did I earn more than I spent", or "did I spend more than I earned"."""
    if query_spec.compare_to == "judge":
        # "is that bad?" after a net cash flow answer
        if net < 0:
            return f"It's not good: you spent about ${-net:.0f} more than you earned."
        return f"That's good: you earned about ${net:.0f} more than you spent."
    spend_first = query_spec.compare_to == "spend_first"
    if net > 0:
        return (
            "No, you earned more than you spent."
            if spend_first
            else "Yes, you earned more than you spent."
        )
    if net < 0:
        return (
            "Yes, you spent more than you earned."
            if spend_first
            else "No, you spent more than you earned."
        )
    return "Income and spending were about equal."


def _exec_month_overview(query_spec, summary, scope_label):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    target = query_spec.period_key
    row = month_index.get(target)
    if not isinstance(row, dict):
        return None
    income = float(row.get("income", 0) or 0)
    expenses = float(row.get("expenses", 0) or 0)
    net = income - expenses
    sign = "+" if net >= 0 else "-"
    if target == date_cls.today().strftime("%Y-%m"):
        opening = f"For {target} so far, {scope_label} has"
    else:
        opening = f"In {target}, {scope_label} had"
    if credit_card_scope(summary):
        # Money into a card is payments and refunds, not income.
        parts = [f"{opening} spending of ${expenses:.0f}."]
    else:
        parts = [
            f"{opening} income of ${income:.0f}, expenses of ${expenses:.0f} and net cash flow "
            f"of {sign}${abs(net):.0f}.{_card_payment_note(summary, [row], 'both')}"
        ]
    top = row.get("top_category") if isinstance(row.get("top_category"), dict) else {}
    top_name = str(top.get("name", "") or "").strip()
    top_amt = float(top.get("amount", 0) or 0)
    if top_name and top_amt > 0:
        parts.append(f"Your biggest category is {top_name} at about ${top_amt:.0f}.")
    prev = _prev_month_key(target)
    prev_row = month_index.get(prev)
    if isinstance(prev_row, dict):
        prev_exp = float(prev_row.get("expenses", 0) or 0)
        parts.append(f"For comparison, {prev} expenses were ${prev_exp:.0f}.")
    return {
        "reply": " ".join(parts),
        "insights": ["Figures are read directly from validated month indexes."],
        "actions": ["Ask about one category or ask for tips to cut spending."],
        "missing_fields": [],
        "facts_used": ["month_index.income", "month_index.expenses", "month_index.top_category"],
        "period_resolved": target,
    }


def _selected_month(summary):
    anchor = summary.get("time_anchor") if isinstance(summary.get("time_anchor"), dict) else {}
    month = str(anchor.get("selected_month", "") or "")
    return month if re.match(r"^20\d{2}-\d{2}$", month) else ""


def _recent_full_months(summary, count=3):
    """Up to `count` complete months before the selected one, newest first."""
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    month = _selected_month(summary)
    keys = []
    while month and len(keys) < count:
        month = _prev_month_key(month)
        if not month or month not in month_index:
            break
        keys.append(month)
    return keys, month_index


def _exec_what_if_cut(query_spec, summary, scope_label):
    try:
        pct = int(query_spec.period_key)
    except (TypeError, ValueError):
        return None
    if pct < 1:
        return None
    category = query_spec.category
    keys, month_index = _recent_full_months(summary)
    values = []
    for key in keys:
        row = month_index[key]
        if category:
            cats = row.get("categories") if isinstance(row.get("categories"), dict) else None
            if cats is None:
                return None
            lowered = {str(k).lower(): float(v or 0) for k, v in cats.items()}
            values.append(lowered.get(category.lower(), 0.0))
        else:
            values.append(float(row.get("expenses", 0) or 0))
    if not values:
        return None
    subject = f"{category} spending" if category else "spending"
    span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
    base = sum(values) / len(values)
    if base <= 0:
        return {
            "reply": (
                f"I don't see any {subject} for {scope_label} over {span}, "
                "so there is nothing to cut there."
            ),
            "insights": ["Checked your recent full months."],
            "actions": ["Ask about a category you spend on, such as your top category."],
            "missing_fields": [],
            "facts_used": ["month_index.categories" if category else "month_index.expenses"],
            "period_resolved": span,
        }
    if pct > 100:
        return {
            "reply": (
                f"A cut of {pct}% isn't possible; the most you can cut is 100%. Dropping "
                f"{subject} entirely would save about ${base:.0f} a month for {scope_label}, "
                f"based on your average over {span}."
            ),
            "insights": ["Savings are calculated from your recent full months, not estimated."],
            "actions": ["Try a cut between 10% and 30% for a realistic target."],
            "missing_fields": [],
            "facts_used": ["month_index.categories" if category else "month_index.expenses"],
            "period_resolved": span,
        }
    monthly = base * pct / 100.0
    lead = f"Cutting out {subject} entirely" if pct == 100 else f"Cutting {subject} by {pct}%"
    return {
        "reply": (
            f"{lead} would save about ${monthly:.0f} a month "
            f"(about ${monthly * 12:.0f} a year) for {scope_label}, based on average monthly "
            f"{subject} of ${base:.0f} over {span}."
        ),
        "insights": ["Savings are calculated from your recent full months, not estimated."],
        "actions": [f"Set a monthly cap of about ${base - monthly:.0f} for {subject}."],
        "missing_fields": [],
        "facts_used": ["month_index.categories" if category else "month_index.expenses"],
        "period_resolved": span,
    }


def _exec_what_if_cut_dollars(query_spec, summary, scope_label):
    try:
        cut = float(query_spec.period_key)
    except (TypeError, ValueError):
        return None
    category = query_spec.category
    keys, month_index = _recent_full_months(summary)
    values = [_month_amount(month_index[k], category) for k in keys]
    if not values or any(v is None for v in values):
        return None
    usual = sum(values) / len(values)
    subject = f"{category} spending" if category else "spending"
    span = keys[-1] if len(keys) == 1 else f"{keys[-1]} to {keys[0]}"
    if usual <= 0:
        return _pointer(
            f"I don't see any {subject} for {scope_label} over {span}, so there's nothing to "
            "cut there.",
            "Ask about a category this account spends on.",
        )
    per_week = query_spec.compare_to == "week"
    weekly_cut = cut
    if per_week:
        cut = weekly_cut * 52 / 12  # a weekly cut, as a monthly amount
    if cut > usual:
        reply = (
            f"Your usual {subject} is about ${usual:.0f} a month ({span}), so cutting ${cut:.0f} "
            f"would mean dropping it entirely, about ${usual * 12:.0f} a year."
        )
    elif per_week:
        reply = (
            f"Cutting {subject} by ${weekly_cut:.0f} a week saves about ${weekly_cut * 52:.0f} a "
            f"year (about ${cut:.0f} a month). That's {cut / usual * 100:.0f}% of your usual "
            f"${usual:.0f} a month ({span})."
        )
    else:
        reply = (
            f"Cutting {subject} by ${cut:.0f} a month saves about ${cut * 12:.0f} a year. That's "
            f"{cut / usual * 100:.0f}% of your usual ${usual:.0f} a month ({span})."
        )
    return {
        "reply": reply,
        "insights": ["Usual = average of your recent full months."],
        "actions": [
            f"Set a {subject} limit of about ${max(usual - cut, 0):.0f} in the Budget tab."
        ],
        "missing_fields": [],
        "facts_used": ["month_index.categories" if category else "month_index.expenses"],
        "period_resolved": span,
    }


def _exec_what_if_cancel(query_spec, summary, scope_label):
    names = [n.strip() for n in (query_spec.category or "").split(",") if n.strip()]
    if len(names) > 1:
        results = [
            _exec_what_if_cancel(dataclasses.replace(query_spec, category=n), summary, scope_label)
            for n in names
        ]
        if any(r is None for r in results):
            return None
        return _join_results(results)
    name = (query_spec.category or "").strip().lower()
    if len(name) < 3:
        return None
    recent = summary.get("recent_transactions")
    if not isinstance(recent, list):
        return None
    for item in recent:
        if not isinstance(item, dict):
            continue
        merchant = str(item.get("name", "") or "").strip()
        amount = float(item.get("amount", 0) or 0)
        if amount > 0 and name in merchant.lower():
            return {
                "reply": (
                    f"Your latest {merchant} charge was ${amount:.2f}. If it bills monthly, "
                    f"cancelling would save about ${amount * 12:.0f} a year for {scope_label}."
                ),
                "insights": ["Based on the most recent charge; check the Subs tab for its cycle."],
                "actions": [
                    f"Confirm {merchant}'s billing cycle in the Subs tab before cancelling."
                ],
                "missing_fields": [],
                "facts_used": ["recent_transactions"],
                "period_resolved": "recent",
            }
    label = name.title()
    return {
        "reply": (
            f"I don't see a recent {label} charge in your latest transactions, so I can't "
            "price cancelling it. The Subs tab lists your recurring charges."
        ),
        "insights": ["Chat sees only your latest few transactions."],
        "actions": [f"Check the Subs tab for {label}'s amount and billing cycle."],
        "missing_fields": [],
        "facts_used": ["recent_transactions"],
        "period_resolved": "recent",
    }


def _exec_amount_day(query_spec, summary, scope_label):
    days = summary.get("day_index_recent")
    if not isinstance(days, dict) or not days:
        return None
    target = query_spec.period_key
    # Days before the window the app sends are unknown, not zero; let other paths answer.
    if not target or target < min(days):
        return None
    row = days.get(target) if isinstance(days.get(target), dict) else {}
    income = float(row.get("income", 0) or 0)
    expenses = float(row.get("expenses", 0) or 0)
    count = int(row.get("tx_count", 0) or 0)
    metric = query_spec.metric
    if metric == "income":
        reply = f"On {target}, income for {scope_label} was about ${income:.0f}."
    elif metric == "net":
        net = income - expenses
        sign = "+" if net >= 0 else "-"
        reply = f"On {target}, net cash flow for {scope_label} was about {sign}${abs(net):.0f}."
    elif expenses > 0:
        noun = "transaction" if count == 1 else "transactions"
        reply = (
            f"On {target}, total expenses for {scope_label} were about ${expenses:.2f} "
            f"across {count} {noun}."
        )
    else:
        reply = f"I don't see any recorded spending on {target} for {scope_label}."
    return {
        "reply": reply,
        "insights": ["Amount derived directly from validated daily totals."],
        "actions": ["Open Activity to see that day's transactions."],
        "missing_fields": [],
        "facts_used": [f"day_index_recent.{metric}"],
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


def _month_scale(key):
    """(factor, (days_elapsed, days_in_month)) to project a month that isn't over yet to a
    full month; (1.0, None) for finished months."""
    today = date_cls.today()
    if key != today.strftime("%Y-%m") or today.day <= 0:
        return 1.0, None
    days = calendar.monthrange(today.year, today.month)[1]
    return days / today.day, (today.day, days)


def _amount_phrase(key, amount):
    """ "$1940 in 2026-09" or "$1234 so far in 2026-10 (19 of 31 days, on pace for $2014)"."""
    factor, progress = _month_scale(key)
    if not progress:
        return f"${amount:.0f} in {key}"
    return (
        f"${amount:.0f} so far in {key} ({progress[0]} of {progress[1]} days, "
        f"on pace for about ${amount * factor:.0f})"
    )


def _lead_with_answer(reply):
    """Move a "Yes." or "No." verdict to the front of the reply."""
    found = re.search(
        r" (Yes|No|Probably yes|Probably not|Probably 20\d{2}-\d{2}|(?:20\d{2}-\d{2}|Q[1-4] 20\d{2}) was "
        r"(?:higher|lower))\. ",
        reply,
    )
    if not found:
        return reply
    return f"{found.group(1)}. " + reply.replace(found.group(0), " ", 1)


def _compare_verdict(left, left_amount, right, right_amount, subject, asked=""):
    """One sentence from the first period's side, so "is October worse than September"
    reads as an answer. A month still in progress is compared at its projected
    full-month total, not its total so far."""
    left_full = left_amount * _month_scale(left)[0]
    right_full = right_amount * _month_scale(right)[0]
    if left_full != left_amount or right_full != right_amount:
        # Speak from the running month's side: "October would end about $74 higher".
        if left_full != left_amount:
            cur, cur_full, other, other_full = left, left_full, right, right_full
        else:
            cur, cur_full, other, other_full = right, right_full, left, left_full
        what = f"{subject.replace(' on ', '').strip()} in {cur}" if subject else cur
        gap = cur_full - other_full
        if abs(gap) < 1:
            return f"At that pace, {what} would end about the same as {other}."
        word = "higher" if gap > 0 else "lower"
        pct = "" if other_full == 0 else f" ({abs(gap) / other_full * 100.0:.1f}% {word})"
        answer = ""
        if asked in {"asked_less", "asked_more"} and cur == left:
            answer = "Probably yes. " if (gap < 0) == (asked == "asked_less") else "Probably not. "
        times = {"asked_double": 2, "asked_triple": 3}.get(asked)
        if times and cur == left:
            answer = "Probably yes. " if cur_full >= times * other_full > 0 else "Probably not. "
        if asked in {"which", "which_lower"}:
            higher = left if left_full > right_full else right
            lower = right if higher == left else left
            answer = f"Probably {higher if asked == 'which' else lower}. "
        return (
            f"{answer}At that pace, {what} would end about ${abs(gap):.0f} {word} than "
            f"{other}{pct}."
        )
    gap = left_amount - right_amount
    if abs(gap) < 1:
        return f"You spent about the same{subject} in {left} and {right}."
    word = "more" if gap > 0 else "less"
    pct = "" if right_amount == 0 else f" ({abs(gap) / right_amount * 100.0:.1f}% {word})"
    answer = ""
    if asked in {"asked_less", "asked_more"}:
        answer = "Yes. " if (gap < 0) == (asked == "asked_less") else "No. "
    elif asked in {"asked_double", "asked_triple"}:
        times = 2 if asked == "asked_double" else 3
        answer = "Yes. " if left_amount >= times * right_amount > 0 else "No. "
        if right_amount > 0:
            pct = f" (about {left_amount / right_amount:.1f} times as much)"
    elif asked == "which":
        answer = f"{left if gap > 0 else right} was higher. "
    elif asked == "which_lower":
        answer = f"{left if gap < 0 else right} was lower. "
    return f"{answer}You spent ${abs(gap):.0f} {word}{subject} in {left} than in {right}{pct}."


def _exec_category_compare(category, left, right, summary, scope_label, asked=""):
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    amounts = []
    for key in (left, right):
        row = month_index.get(key)
        if not isinstance(row, dict) or not isinstance(row.get("categories"), dict):
            return None
        lowered = {str(k).lower(): float(v or 0) for k, v in row["categories"].items()}
        amounts.append(lowered.get(category.lower(), 0.0))
    left_amount, right_amount = amounts
    if left_amount < 1 and right_amount < 1:
        return _pointer(
            f"I don't see any {category} spending for {scope_label} in {left} or {right}.",
            f"Ask which months had {category} spending.",
        )
    verdict = _compare_verdict(left, left_amount, right, right_amount, f" on {category}", asked)
    return {
        "reply": _lead_with_answer(
            f"{category} spending for {scope_label}: {_amount_phrase(left, left_amount)} vs "
            f"{_amount_phrase(right, right_amount)}. {verdict}"
        ),
        "insights": ["Category amounts are read directly from validated month indexes."],
        "actions": [f"Ask for {category} transactions to see what changed."],
        "missing_fields": [],
        "facts_used": ["month_index.categories"],
        "period_resolved": f"{left} vs {right}",
    }


def _exec_compare_income_or_net(metric, left, right, summary, scope_label, asked=""):
    """Income or net cash flow for two months; a month still running is "so far"."""
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    values = {}
    for key in (left, right):
        row = month_index.get(key)
        if not isinstance(row, dict):
            return None
        income = float(row.get("income", 0) or 0)
        values[key] = income - float(row.get("expenses", 0) or 0) if metric == "net" else income
    current = date_cls.today().strftime("%Y-%m")

    def phrase(key):
        value = values[key]
        amount = (
            f"{'+' if value >= 0 else '-'}${abs(value):.0f}"
            if metric == "net"
            else (f"${value:.0f}")
        )
        return f"{amount} so far in {key}" if key == current else f"{amount} in {key}"

    diff = values[left] - values[right]
    subject = "Net cash flow" if metric == "net" else "Income"
    if abs(diff) < 1:
        verdict = "About the same."
    else:
        word = "higher" if diff > 0 else "lower"
        if current in (left, right):
            verdict = f"So far {left} is ${abs(diff):.0f} {word}, and {current} isn't over yet."
        else:
            verdict = f"{left} is ${abs(diff):.0f} {word}."
            if asked in {"asked_less", "asked_more"}:
                verdict = ("Yes. " if (diff < 0) == (asked == "asked_less") else "No. ") + verdict
            elif asked in {"asked_double", "asked_triple"} and metric == "income":
                times = 2 if asked == "asked_double" else 3
                grew = values[right] > 0 and values[left] >= times * values[right]
                verdict = ("Yes. " if grew else "No. ") + verdict
            higher, lower = (left, right) if diff > 0 else (right, left)
            lead = {
                "which": f"{higher} was higher. ",
                "which_lower": f"{lower} was lower. ",
                "which_better": f"You were better off in {higher}. ",
                "which_worse": f"You were worse off in {lower}. ",
            }.get(asked, "")
            if lead:
                return {
                    "reply": f"{lead}{subject} for {scope_label}: {phrase(left)} vs "
                    f"{phrase(right)}. {verdict}",
                    "insights": ["Net cash flow = income minus expenses for each month."],
                    "actions": ["Ask what changed in spending between these months."],
                    "missing_fields": [],
                    "facts_used": ["month_index.income", "month_index.expenses"],
                    "period_resolved": f"{left} vs {right}",
                }
    return {
        "reply": _lead_with_answer(
            f"{subject} for {scope_label}: {phrase(left)} vs {phrase(right)}. {verdict}"
        ),
        "insights": ["Net cash flow = income minus expenses for each month."],
        "actions": ["Ask what changed in spending between these months."],
        "missing_fields": [],
        "facts_used": ["month_index.income", "month_index.expenses"],
        "period_resolved": f"{left} vs {right}",
    }


def _cap(text):
    return text[:1].upper() + text[1:]


def _group_name(label):
    """ "2026-Q3" -> "Q3 2026", "2026-H1" -> "the first half of 2026", "2026-S2" ->
    "summer 2026"."""
    year, kind, part = label[:4], label[5], int(label[6:])
    if kind == "H":
        return f"the {'first' if part == 1 else 'second'} half of {year}"
    if kind == "S":
        return f"{('spring', 'summer', 'fall', 'winter')[part - 1]} {year}"
    return f"Q{part} {year}"


def _exec_compare_quarters(query_spec, summary, scope_label):
    """ "did I earn more in Q2 or Q3", "the first half or the second half": each one
    summed over its months."""
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    current = date_cls.today().strftime("%Y-%m")
    metric = query_spec.metric if query_spec.metric in {"income", "net"} else "expenses"
    category = (query_spec.category or "").strip()
    sides = []
    for label in (query_spec.period_key or "").split(","):
        keys = group_months(label)
        present = [k for k in keys if isinstance(month_index.get(k), dict)]
        if not present:
            return _missing_month_reply(
                keys[0] if keys[0] > current else keys[-1], month_index
            ) or _pointer(
                f"I don't have any data for {_group_name(label)} for {scope_label}.",
                "Ask about the months your data covers.",
            )
        total = 0.0
        for key in present:
            row = month_index[key]
            if category:
                total += _month_amount(row, category) or 0.0
            elif metric == "net":
                total += float(row.get("income", 0) or 0) - float(row.get("expenses", 0) or 0)
            else:
                total += float(row.get(metric, 0) or 0)
        if query_spec.reason_mode == "projected" and current in present and metric == "expenses":
            # this month at its pace, the months still to come at your recent monthly average
            recent, recent_index = _recent_full_months(summary)
            usual = [(_month_amount(recent_index[k], category) or 0.0) for k in recent]
            row = month_index[current]
            now = _month_amount(row, category) or 0.0
            total += now * (_month_scale(current)[0] - 1)
            later = [k for k in keys if k > current]
            if usual:
                total += len(later) * sum(usual) / len(usual)
            sides.append(
                (
                    _group_name(label),
                    total,
                    f"about ${total:.0f} projected for {_group_name(label)} "
                    f"(${now:.0f} so far in {current}, the rest at your recent pace)",
                    False,
                )
            )
            continue
        name = _group_name(label)
        months = present[0] if len(present) == 1 else f"{present[0]} to {present[-1]}"
        if current in present:
            months += ", so far"
        elif len(present) < len(keys):
            months += " only"
        shown = (
            f"{'+' if total >= 0 else '-'}${abs(total):.0f}" if metric == "net" else f"${total:.0f}"
        )
        sides.append((name, total, f"{shown} in {name} ({months})", current in present))
    (left, left_total, left_text, left_open), (right, right_total, right_text, right_open) = sides
    subject = (
        f"{category} spending"
        if category
        else {"income": "Income", "net": "Net cash flow"}.get(metric, "Spending")
    )
    diff = left_total - right_total
    running = left_open or right_open
    lead = ""
    if abs(diff) < 1:
        verdict = f"{_cap(left)} and {right} were about the same."
    else:
        word = "higher" if diff > 0 else "lower"
        verdict = f"{_cap(left)} was ${abs(diff):.0f} {word} than {right}"
        verdict += (
            ", and it isn't over yet."
            if left_open
            else (f", and {right} isn't over yet." if right_open else ".")
        )
        asked = query_spec.compare_to
        if asked == "which" and not running:
            lead = f"{_cap(left if diff > 0 else right)} was higher. "
        elif asked == "which_lower" and not running:
            lead = f"{_cap(left if diff < 0 else right)} was lower. "
        elif asked in {"asked_less", "asked_more"} and not running:
            lead = "Yes. " if (diff < 0) == (asked == "asked_less") else "No. "
        if query_spec.reason_mode == "projected" and "projected" in left_text + right_text:
            verdict = f"That would be about ${abs(diff):.0f} {word} than {right}."
            lead = {"Yes. ": "Probably yes. ", "No. ": "Probably not. "}.get(lead, lead)
    return {
        "reply": f"{lead}{subject} for {scope_label}: {left_text} vs {right_text}. {verdict}",
        "insights": ["Each quarter is the sum of its months in the validated month index."],
        "actions": ["Ask which months drove the difference."],
        "missing_fields": [],
        "facts_used": ["month_index"],
        "period_resolved": f"{left} vs {right}",
    }


def _exec_compare_periods(query_spec, summary, scope_label):
    period_key = query_spec.period_key or ""
    parts = [x.strip() for x in period_key.split(",") if x.strip()]
    if len(parts) < 2:
        return None
    if query_spec.period_type == "quarters":
        return _exec_compare_quarters(query_spec, summary, scope_label)
    names = [n.strip() for n in (query_spec.category or "").split(",") if n.strip()]
    if len(parts) > 2 or query_spec.reason_mode == "series":
        if len(names) > 1:
            results = []
            for name in names:
                spec = dataclasses.replace(query_spec, category=name)
                result = _exec_compare_many(spec, parts, summary, scope_label)
                if result is None:
                    return None
                results.append(result)
            return _join_results(results)
        return _exec_compare_many(query_spec, parts, summary, scope_label)
    left, right = parts[0], parts[1]
    month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
    for key in (right, left):
        if re.match(r"^20\d{2}-\d{2}$", key) and key not in month_index:
            missing = _missing_month_reply(key, month_index)
            if missing:
                return missing
    if len(names) > 1:
        results = [
            _exec_category_compare(name, left, right, summary, scope_label) for name in names
        ]
        if any(r is None for r in results):
            return None
        return _join_results(results)
    if names:
        return _exec_category_compare(
            names[0], left, right, summary, scope_label, query_spec.compare_to
        )
    if query_spec.metric in {"income", "net"}:
        return _exec_compare_income_or_net(
            query_spec.metric, left, right, summary, scope_label, query_spec.compare_to
        )
    left_amount, left_kind = _lookup_period_expense(left, summary)
    right_amount, right_kind = _lookup_period_expense(right, summary)
    if left_amount is None or right_amount is None or left_kind != right_kind:
        return None
    verdict = _compare_verdict(left, left_amount, right, right_amount, "", query_spec.compare_to)
    return {
        "reply": _lead_with_answer(
            f"Spending for {scope_label}: {_amount_phrase(left, left_amount)} vs "
            f"{_amount_phrase(right, right_amount)}. {verdict}"
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
    mode = query_spec.reason_mode or ""
    if mode.startswith("rank:") and period_type == "year":
        totals = {}
        for key, row in month_index.items():
            cats = row.get("categories") if isinstance(row, dict) else None
            if str(key).startswith(f"{period_key}-") and isinstance(cats, dict):
                for name, amount in cats.items():
                    totals[str(name)] = totals.get(str(name), 0.0) + float(amount or 0)
        n = int(mode.split(":")[1])
        ranked = sorted(totals.items(), key=lambda kv: -kv[1])
        if len(ranked) >= n:
            name, amount = ranked[n - 1]
            place = "top category" if n == 1 else f"number {n} category"
            return {
                "reply": (
                    f"In {period_key} so far, your {place} for {scope_label} is {name} at about "
                    f"${amount:.0f}."
                ),
                "insights": ["Category totals are summed from validated month indexes."],
                "actions": ["Ask how it compares month to month."],
                "missing_fields": [],
                "facts_used": ["month_index.categories"],
                "period_resolved": period_key,
            }
    if mode.startswith("top:") and period_type == "year":
        totals = {}
        for key, row in month_index.items():
            cats = row.get("categories") if isinstance(row, dict) else None
            if str(key).startswith(f"{period_key}-") and isinstance(cats, dict):
                for name, amount in cats.items():
                    totals[str(name)] = totals.get(str(name), 0.0) + float(amount or 0)
        if totals:
            n = int(mode.split(":")[1])
            ranked = sorted(totals.items(), key=lambda kv: -kv[1])[:n]
            listed = ", ".join(f"{k} ${v:.0f}" for k, v in ranked)
            return {
                "reply": (
                    f"In {period_key} so far, your top {len(ranked)} categories for {scope_label}: "
                    f"{listed}."
                ),
                "insights": ["Category totals are summed from validated month indexes."],
                "actions": ["Ask how one of these compares month to month."],
                "missing_fields": [],
                "facts_used": ["month_index.categories"],
                "period_resolved": period_key,
            }
    if mode == "is_top":
        row = month_index.get(period_key)
        cats = row.get("categories") if isinstance(row, dict) else None
        if not isinstance(cats, dict) or not cats:
            return None
        ranked = sorted(((str(k), float(v or 0)) for k, v in cats.items()), key=lambda kv: -kv[1])
        asked = query_spec.category
        top_name, top_amount = ranked[0]
        if top_name.lower() == asked.lower():
            reply = (
                f"Yes. {asked} is your biggest category in {period_key} at about ${top_amount:.0f}."
            )
        else:
            place = next((i for i, (k, _) in enumerate(ranked, 1) if k.lower() == asked.lower()), 0)
            amount = dict((k.lower(), v) for k, v in ranked).get(asked.lower(), 0.0)
            second = (
                f"{asked} is number {place} at about ${amount:.0f}."
                if place
                else f"{asked} has no spending that month."
            )
            reply = (
                f"No. {top_name} is your biggest category in {period_key} at about "
                f"${top_amount:.0f}; {second}"
            )
        return {
            "reply": f"{reply} (For {scope_label}.)",
            "insights": ["Category ranking is read directly from validated month indexes."],
            "actions": ["Ask for your top categories that month."],
            "missing_fields": [],
            "facts_used": ["month_index.categories"],
            "period_resolved": period_key,
        }
    if mode == "ever":
        totals = {}
        for row in month_index.values():
            cats = row.get("categories") if isinstance(row, dict) else None
            for name, amount in (cats or {}).items():
                totals[str(name)] = totals.get(str(name), 0.0) + float(amount or 0)
        if not totals:
            return None
        name, amount = max(totals.items(), key=lambda kv: kv[1])
        keys = sorted(month_index)
        return {
            "reply": (
                f"Across all your data ({keys[0]} to {keys[-1]}), your biggest category for "
                f"{scope_label} is {name} at about ${amount:.0f} in total."
            ),
            "insights": ["Summed over every month with category data."],
            "actions": [f"Ask how {name} has trended month to month."],
            "missing_fields": [],
            "facts_used": ["month_index.categories"],
            "period_resolved": f"{keys[0]} to {keys[-1]}",
        }
    if period_type == "month_range" and (
        not mode or mode == "avg" or mode.startswith(("top:", "rank:"))
    ):
        keys = [k for k in (period_key or "").split(",") if k in month_index]
        totals = {}
        for key in keys:
            cats = month_index[key].get("categories")
            for name, amount in (cats or {}).items() if isinstance(cats, dict) else []:
                totals[str(name)] = totals.get(str(name), 0.0) + float(amount or 0)
        if not keys:
            return None
        span = keys[0] if len(keys) == 1 else f"{keys[0]} to {keys[-1]}"
        if not totals:
            return _pointer(
                f"{scope_label} has no spending split by category in {span}; it's all "
                "transfers and payments.",
                "Ask for the total spending over those months.",
            )
        ranked = sorted(totals.items(), key=lambda kv: -kv[1])
        name, amount = ranked[0]
        others = ", ".join(f"{k} ${v:.0f}" for k, v in ranked[1:3])
        reply = (
            f"From {span}, your top category for {scope_label} was {name} at about ${amount:.0f}"
        )
        reply += f", ahead of {others}." if others else "."
        if mode == "rank:last":
            name, amount = ranked[-1]
            reply = (
                f"From {span}, your smallest category with spending for {scope_label} was "
                f"{name} at about ${amount:.0f}."
            )
        elif mode.startswith("rank:") and int(mode.split(":")[1]) > 1:
            n = int(mode.split(":")[1])
            if n > len(ranked):
                count = "one category" if len(ranked) == 1 else f"{len(ranked)} categories"
                reply = f"{span} only has {count} with spending."
            else:
                name, amount = ranked[n - 1]
                reply = (
                    f"From {span}, your number {n} category for {scope_label} was {name} at "
                    f"about ${amount:.0f}."
                )
        elif mode.startswith("top:"):
            listed = ", ".join(f"{k} ${v:.0f}" for k, v in ranked[: int(mode.split(":")[1])])
            reply = f"From {span}, your spending by category for {scope_label}: {listed}."
        elif mode == "avg":
            # "my biggest monthly expense": per-month averages
            months = len(keys)
            others = ", ".join(f"{k} ${v / months:.0f}" for k, v in ranked[1:3])
            reply = (
                f"Your biggest monthly expense for {scope_label} is {name}, about "
                f"${amount / months:.0f} a month on average ({span})"
            )
            reply += f", ahead of {others}." if others else "."
        spent = sum(float(month_index[k].get("expenses", 0) or 0) for k in keys)
        unsplit = spent - sum(totals.values())
        if unsplit >= 1 and unsplit >= 0.5 * spent:
            reply += (
                f" Most of the ${spent:.0f} spent then (about ${unsplit:.0f}) was transfers and "
                "payments, which have no category."
            )
        return {
            "reply": reply,
            "insights": ["Category totals are summed from validated month indexes."],
            "actions": [f"Ask how {name} changed month to month."],
            "missing_fields": [],
            "facts_used": ["month_index.categories"],
            "period_resolved": span,
        }
    if period_type == "month_list":
        parts = []
        for key in [k.strip() for k in (period_key or "").split(",") if k.strip()]:
            row = month_index.get(key)
            top = row.get("top_category") if isinstance(row, dict) else None
            if not isinstance(top, dict) or not top.get("name"):
                return None
            parts.append(f"{key}: {top['name']} (${float(top.get('amount', 0) or 0):.0f})")
        return {
            "reply": f"Top category for {scope_label} by month: {'; '.join(parts)}.",
            "insights": ["Top categories are read directly from validated month indexes."],
            "actions": ["Ask how a category changed between these months."],
            "missing_fields": [],
            "facts_used": ["month_index.top_category"],
            "period_resolved": period_key,
        }
    if mode.startswith(("rank:", "top:")) and period_type == "month":
        row = month_index.get(period_key)
        cats = row.get("categories") if isinstance(row, dict) else None
        if isinstance(cats, dict) and not cats and float(row.get("expenses", 0) or 0) > 0:
            return _pointer(
                f"{scope_label} has no spending split by category in {period_key}; it's all "
                "transfers and payments.",
                "Ask for that month's total spending.",
            )
        if isinstance(cats, dict) and cats:
            ranked = sorted(
                ((str(k), float(v or 0)) for k, v in cats.items()), key=lambda kv: -kv[1]
            )
            if mode == "rank:last":
                name, amount = ranked[-1]
                claim = query_spec.category
                lead = ""
                if claim:
                    lead = "Yes. " if claim.lower() == name.lower() else f"No, not {claim}. "
                return {
                    "reply": (
                        f"{lead}For {period_key}, your smallest category with spending for "
                        f"{scope_label} is {name} at about ${amount:.0f}."
                    ),
                    "insights": ["Category ranking is read directly from validated month indexes."],
                    "actions": ["Ask for your top categories that month."],
                    "missing_fields": [],
                    "facts_used": ["month_index.categories"],
                    "period_resolved": period_key,
                }
            n = int(mode.split(":")[1])
            if mode.startswith("rank:"):
                if n > len(ranked):
                    reply = f"{period_key} only has {len(ranked)} categories with spending."
                else:
                    name, amount = ranked[n - 1]
                    reply = (
                        f"For {period_key}, your number {n} category for {scope_label} is "
                        f"{name} at about ${amount:.0f}."
                    )
            else:
                listed = ", ".join(f"{k} ${v:.0f}" for k, v in ranked[:n])
                if mode == "top:12":
                    reply = (
                        f"For {period_key}, your spending by category for {scope_label}: {listed}."
                    )
                else:
                    shown = min(n, len(ranked))
                    if shown == 1:
                        reply = (
                            f"For {period_key}, {scope_label} had spending in one category: "
                            f"{listed}."
                        )
                    else:
                        reply = (
                            f"For {period_key}, your top {shown} categories for {scope_label}: "
                            f"{listed}."
                        )
            return {
                "reply": reply,
                "insights": ["Category ranking is read directly from validated month indexes."],
                "actions": ["Ask how one of these compares with last month."],
                "missing_fields": [],
                "facts_used": ["month_index.categories"],
                "period_resolved": period_key,
            }
    if period_type == "month" and period_key:
        row = month_index.get(period_key)
        cats = row.get("categories") if isinstance(row, dict) else None
        if isinstance(cats, dict) and not cats and float(row.get("expenses", 0) or 0) > 0:
            return _pointer(
                f"{scope_label} has no spending split by category in {period_key}; it's all "
                "transfers and payments.",
                "Ask for that month's total spending.",
            )
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


def _exec_recent_transactions(summary, scope_label, query_spec=None):
    recent = (
        summary.get("recent_transactions")
        if isinstance(summary.get("recent_transactions"), list)
        else []
    )
    if not recent:
        return None
    if getattr(query_spec, "period_type", "") == "category":
        category = query_spec.category
        rows = [
            f"{item.get('date', '')} {item.get('name', '')} "
            f"{describe_plaid_amount(float(item.get('amount', 0) or 0))}"
            for item in recent
            if isinstance(item, dict) and str(item.get("category", "")).lower() == category.lower()
        ]
        listed = f": {'; '.join(rows)}." if rows else " none of them are."
        return {
            "reply": (
                f"Of your {len(recent)} most recent transactions, these are {category}{listed} "
                f"Chat only sees the latest few; Activity lists every {category} transaction."
            ),
            "insights": ["Read from the latest transactions the app sends."],
            "actions": [f"Open Activity and search or filter for {category}."],
            "missing_fields": [],
            "facts_used": ["recent_transactions"],
            "period_resolved": "recent",
        }
    month_key = ""
    if getattr(query_spec, "period_type", "") in {"month", "day"}:
        month_key = str(getattr(query_spec, "period_key", "") or "")
    rows = []
    for item in recent:
        if not isinstance(item, dict):
            continue
        d = str(item.get("date", "") or "").strip()
        n = str(item.get("name", "") or "Transaction").strip()
        a = float(item.get("amount", 0) or 0)
        if not d or (month_key and not d.startswith(month_key)):
            continue
        rows.append(f"{d} {n} {describe_plaid_amount(a)}")
        if len(rows) == 5:
            break
    days = (
        summary.get("day_index_recent") if isinstance(summary.get("day_index_recent"), dict) else {}
    )
    day_row = days.get(month_key) if month_key and len(month_key) == 10 else None
    if (
        month_key
        and not rows
        and days
        and month_key >= min(days)
        and not (isinstance(day_row, dict) and float(day_row.get("expenses", 0) or 0) > 0)
    ):
        return _pointer(
            f"I don't see any spending for {scope_label} on {month_key}.",
            "Ask about another day.",
        )
    if month_key and not rows:
        # The app only sends the latest few rows, so say so instead of guessing.
        return {
            "reply": (
                f"I can only see your {len(recent)} most recent transactions for {scope_label}, "
                f"and none of them are from {month_key}."
            ),
            "insights": ["Chat reads the latest transactions only, not full month history."],
            "actions": [f"Open Activity and pick {month_key} to see every transaction."],
            "missing_fields": [],
            "facts_used": ["recent_transactions"],
            "period_resolved": month_key,
        }
    if not rows:
        return None
    if month_key:
        return {
            "reply": (
                f"Most recent transactions {'on' if len(month_key) == 10 else 'in'} {month_key} "
                f"for {scope_label}: {'; '.join(rows)}."
            ),
            "insights": ["Recent transactions are read directly from validated summary rows."],
            "actions": [f"Open Activity and pick {month_key} for the full list."],
            "missing_fields": [],
            "facts_used": ["recent_transactions"],
            "period_resolved": month_key,
        }
    return {
        "reply": f"Most recent transactions for {scope_label}: {'; '.join(rows)}.",
        "insights": ["Recent transactions are read directly from validated summary rows."],
        "actions": ["Ask for a specific date range or merchant if you want a narrower slice."],
        "missing_fields": [],
        "facts_used": ["recent_transactions"],
        "period_resolved": "recent",
    }
