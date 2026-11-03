"""Every kind of question asked over several months or a run of days: chat answers for
that period or says it can't, never for a different one. The summary is built from
made-up transactions by the server's own builder, dated back from today."""

import datetime as dt
import os
import unittest
from unittest import mock

from ai import server_summary
from ai.asked_period import asked_period, covers, shows_other_period
from ai.chat_service import ChatService
from ai.query_parser_v2 import _normalize

ASKS = {
    "spend": "How much did I spend {r}?",
    "category": "How much did I spend on food {r}?",
    "income": "What was my income {r}?",
    "net": "What was my cash flow {r}?",
    "budget": "Have I been on budget {r}?",
    "over": "Was I over budget {r}?",
    "top_category": "What was my top spending category {r}?",
    "biggest": "What was my biggest purchase {r}?",
    "count": "How many transactions did I make {r}?",
    "daily_average": "What's my average daily spending {r}?",
    "subscriptions": "How much did I pay for subscriptions {r}?",
    "merchant": "How much did I spend at Cava {r}?",
    "trend": "Is my spending going up {r}?",
}

# Kinds chat answers for several months, and for a run of days.
MONTHS_ANSWERED = set(ASKS) - {"merchant"}
DAYS_ANSWERED = {"spend", "count", "daily_average"}
# "Is my spending going up since September" compares the running month's pace with
# September, which doesn't cover the months between, so chat says it can't.
NOT_ANSWERED = {("trend", "since")}


def month_name(month_key):
    return dt.date.fromisoformat(f"{month_key}-01").strftime("%B")


def ranges(today):
    """(kind, label, wording) for each period asked. "This year" needs two months."""

    def back(n):
        year, month = today.year, today.month - n
        while month <= 0:
            month, year = month + 12, year - 1
        return f"{year}-{month:02d}"

    asked = [
        ("months", "last_3", "in the last 3 months"),
        ("months", "few", "in the past few months"),
        ("months", "since", f"since {month_name(back(2))}"),
        ("months", "between", f"between {month_name(back(3))} and {month_name(back(2))}"),
        ("days", "two_weeks", "over the past 2 weeks"),
        ("days", "ten_days", "in the last 10 days"),
        ("days", "this_week", "this week"),
        ("days", "last_week", "last week"),
    ]
    if today.month >= 2:
        asked.append(("months", "year", "this year"))
    return asked


def build_summary(today):
    """Ten months of transactions up to today: pay on the 1st, food every other day,
    a ride every 5 days, shopping weekly, a subscription monthly."""
    rows = []
    start = today - dt.timedelta(days=300)
    day = start
    n = 0
    while day <= today:

        def add(name, amount, primary, detailed, account="acc-card"):
            nonlocal n
            n += 1
            rows.append(
                {
                    "plaid_transaction_id": f"tx-{n}",
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

        ordinal = day.toordinal()
        if day.day == 1:
            add("ACME PAYROLL", -2500, "INCOME", "INCOME_WAGES", "acc-checking")
        if ordinal % 2 == 0:
            add("Cava", 12 + ordinal % 9, "FOOD_AND_DRINK", "FOOD_AND_DRINK_RESTAURANT")
        if ordinal % 5 == 0:
            add("Uber", 15 + ordinal % 7, "TRANSPORTATION", "TRANSPORTATION_TAXIS_AND_RIDE_SHARES")
        if day.weekday() == 5:
            add("Target", 40 + ordinal % 60, "GENERAL_MERCHANDISE", "GENERAL_MERCHANDISE_OTHER")
        if day.day == 5:
            add("Netflix", 15.49, "ENTERTAINMENT", "ENTERTAINMENT_TV_AND_MOVIES")
        day += dt.timedelta(days=1)
    accounts = {
        "acc-checking": {
            "plaid_account_id": "acc-checking",
            "name": "Checking",
            "account_type": "depository",
            "subtype": "checking",
        },
        "acc-card": {
            "plaid_account_id": "acc-card",
            "name": "Card",
            "account_type": "credit",
            "subtype": "credit card",
        },
    }
    txs = server_summary.build_transactions(rows, accounts, {}, None, {})
    summary = server_summary.build_summary(
        txs,
        [],
        now=dt.datetime.combine(today, dt.time(12, 0)),
        focus_month=today.strftime("%Y-%m"),
        all_year=False,
        all_accounts=True,
        scope_label="Overall (All Accounts)",
        tz_name="",
    )

    def budget(month):
        cats = summary["month_index"].get(month, {}).get("categories", {})
        return {
            "month": month,
            "items": [
                {"category": "Food", "spent": cats.get("Food", 0.0), "limit": 220.0},
                {"category": "Shopping", "spent": cats.get("Shopping", 0.0), "limit": 200.0},
            ],
        }

    current = today.strftime("%Y-%m")
    summary["budgets"] = budget(current)
    summary["budget_history"] = {m: budget(m) for m in summary["month_index"] if m < current}
    return summary


class PeriodRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.today = dt.date.today()
        cls.summary = build_summary(cls.today)
        cls.ranges = ranges(cls.today)

    def setUp(self):
        patcher = mock.patch.dict(os.environ, {"AI_ROUTER_V2_ENABLED": "1"})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.service = ChatService(
            generate_reply=lambda _prompt, generation_config=None: "NONE",
            get_detailed_snapshot=lambda _uid: "",
        )

    def ask(self, prompt):
        return self.service.handle_chat(
            {"prompt": prompt, "history": [], "spending_summary": self.summary},
            user_id="demo-user",
        )

    def cases(self):
        for kind, template in ASKS.items():
            for span, label, wording in self.ranges:
                yield kind, span, label, template.format(r=wording)

    def test_never_answers_for_a_different_period(self):
        for kind, _span, _label, prompt in self.cases():
            with self.subTest(prompt=prompt):
                response = self.ask(prompt)
                reply = response["reply"]
                self.assertTrue(reply)
                asked = asked_period(_normalize(prompt), self.summary)
                self.assertIsNotNone(asked)
                said_why = ChatService._LIMIT_SAID_RE.search(reply) and not shows_other_period(
                    asked, response, self.summary
                )
                self.assertTrue(
                    covers(asked, response, self.summary)
                    or reply.startswith("I can't answer that")
                    or said_why,
                    reply,
                )

    def test_answers_the_kinds_chat_supports(self):
        for kind, span, label, prompt in self.cases():
            supported = MONTHS_ANSWERED if span == "months" else DAYS_ANSWERED
            if kind not in supported or (kind, label) in NOT_ANSWERED or label == "last_week":
                continue
            with self.subTest(prompt=prompt):
                reply = self.ask(prompt)["reply"]
                self.assertFalse(reply.startswith("I can't answer that"), reply)
                self.assertNotIn("Chat only gets the budgets", reply)


if __name__ == "__main__":
    unittest.main()
