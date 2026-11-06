"""The made-up account behind the chat exam (tests/test_chat_exam.py). Frozen: the exam's
expected answers were worked out from these rows by hand-checkable arithmetic, so any
change here invalidates tests/data/chat_exam_v1.json.

Today is 2026-06-15. The data runs from 2025-07-01: pay of $2,500 on the 1st and 15th
(only the 1st in February 2026), $10 at Corner Deli every day, Uber $20 on the 5th, 15th
and 25th, Target $60 on the 10th, Costco $150 on the 20th of odd months, Regal Cinemas
$30 on the 12th, Spotify $11.99 on the 3rd, Netflix $15.49 on the 8th, an Apple Store
laptop for $1,200 on 2026-03-07 and $50 back from Costco on 2026-04-22."""

import datetime as dt

TODAY = dt.date(2026, 6, 15)
START = dt.date(2025, 7, 1)

ACCOUNTS = {
    "acc-checking": {
        "plaid_account_id": "acc-checking",
        "name": "Everyday Checking",
        "account_type": "depository",
        "subtype": "checking",
    },
    "acc-card": {
        "plaid_account_id": "acc-card",
        "name": "Rewards Card",
        "account_type": "credit",
        "subtype": "credit card",
    },
}

SUBSCRIPTIONS = [
    {
        "name": "Spotify",
        "amount": 11.99,
        "frequency": "monthly",
        "next_charge": "2026-07-03",
        "unconfirmed": False,
    },
    {
        "name": "Netflix",
        "amount": 15.49,
        "frequency": "monthly",
        "next_charge": "2026-07-08",
        "unconfirmed": False,
    },
]

# Monthly limits on the Budget tab, the same every month.
BUDGET_LIMITS = {"Food": 305.0, "Shopping": 300.0, "Transport": 65.0}


def rows():
    out = []

    def add(day, name, amount, primary, detailed, account="acc-card"):
        out.append(
            {
                "plaid_transaction_id": f"tx-{len(out) + 1}",
                "plaid_account_id": account,
                "amount": amount,
                "date": day.isoformat(),
                "name": name,
                "merchant_name": name,
                "pfc_primary": primary,
                "pfc_detailed": detailed,
                "category": None,
                "pfc_confidence": "high",
                "pending": False,
            }
        )

    day = START
    while day <= TODAY:
        if day.day == 1 or (day.day == 15 and (day.year, day.month) != (2026, 2)):
            add(day, "ACME PAYROLL", -2500.0, "INCOME", "INCOME_WAGES", "acc-checking")
        add(day, "Corner Deli", 10.0, "FOOD_AND_DRINK", "FOOD_AND_DRINK_RESTAURANT")
        if day.day in (5, 15, 25):
            add(day, "Uber", 20.0, "TRANSPORTATION", "TRANSPORTATION_TAXIS_AND_RIDE_SHARES")
        if day.day == 10:
            add(day, "Target", 60.0, "GENERAL_MERCHANDISE", "GENERAL_MERCHANDISE_SUPERSTORES")
        if day.day == 20 and day.month % 2 == 1:
            add(day, "Costco", 150.0, "GENERAL_MERCHANDISE", "GENERAL_MERCHANDISE_SUPERSTORES")
        if day.day == 12:
            add(day, "Regal Cinemas", 30.0, "ENTERTAINMENT", "ENTERTAINMENT_TV_AND_MOVIES")
        if day.day == 3:
            add(day, "Spotify", 11.99, "ENTERTAINMENT", "ENTERTAINMENT_MUSIC_AND_AUDIO")
        if day.day == 8:
            add(day, "Netflix", 15.49, "ENTERTAINMENT", "ENTERTAINMENT_TV_AND_MOVIES")
        if day == dt.date(2026, 3, 7):
            add(
                day, "Apple Store", 1200.0, "GENERAL_MERCHANDISE", "GENERAL_MERCHANDISE_ELECTRONICS"
            )
        if day == dt.date(2026, 4, 22):
            add(day, "Costco", -50.0, "GENERAL_MERCHANDISE", "GENERAL_MERCHANDISE_SUPERSTORES")
        day += dt.timedelta(days=1)
    return out


def pin_today(case, today=TODAY):
    """Pin today (TODAY unless given) for a test case, in every module that reads the
    date."""
    import types
    from unittest import mock

    from ai import (
        asked_period,
        chat_service,
        intent_router,
        query_executors_v2,
        query_parser_v2,
        time_parsing,
        time_scope_resolver,
    )

    class _ExamDate(dt.date):
        @classmethod
        def today(cls):
            return today

    patches = [mock.patch.dict("os.environ", {"AI_ROUTER_V2_ENABLED": "1"})]
    for module in (
        chat_service,
        intent_router,
        query_executors_v2,
        query_parser_v2,
        time_parsing,
        time_scope_resolver,
    ):
        patches.append(mock.patch.object(module, "date_cls", _ExamDate))
    exam_dt = types.SimpleNamespace(date=_ExamDate, timedelta=dt.timedelta, datetime=dt.datetime)
    patches.append(mock.patch.object(asked_period, "dt", exam_dt))
    for patch in patches:
        patch.start()
        case.addCleanup(patch.stop)


def summary():
    """The chat summary for this account, built by the server's own code, with
    the server-only blocks the app's summary lacks."""
    from ai import server_summary

    txs = server_summary.build_transactions(rows(), ACCOUNTS, {}, None, {})
    built = server_summary.build_summary(
        txs,
        [],
        now=dt.datetime.combine(TODAY, dt.time(12, 0)),
        focus_month=TODAY.strftime("%Y-%m"),
        all_year=False,
        all_accounts=True,
        scope_label="Overall (All Accounts)",
        tz_name="",
    )
    built["merchant_index"], built["category_counts"] = server_summary.spending_detail(txs)
    built["income_index"] = server_summary.income_detail(txs)

    def budget(month):
        cats = built["month_index"].get(month, {}).get("categories", {})
        return {
            "month": month,
            "items": [
                {"category": name, "spent": round(cats.get(name, 0.0), 2), "limit": limit}
                for name, limit in BUDGET_LIMITS.items()
            ],
        }

    current = TODAY.strftime("%Y-%m")
    built["budgets"] = budget(current)
    built["budget_history"] = {m: budget(m) for m in built["month_index"] if m < current}
    built["subscriptions"] = [dict(s) for s in SUBSCRIPTIONS]
    return built
