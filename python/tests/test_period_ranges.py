"""Answers for several months or a run of days: each kind of question adds up the
period asked instead of answering for one month."""

import datetime as dt
import os
import unittest
from unittest import mock

from ai.chat_service import ChatService


def months_summary():
    """Feb to May 2026, May selected."""
    return {
        "scope": "all_accounts",
        "scope_label": "Overall (All Accounts)",
        "time_anchor": {"selected_month": "2026-05", "selected_year": 2026},
        "month_index": {
            "2026-02": {
                "income": 1500.0,
                "expenses": 400.0,
                "tx_count": 20,
                "expense_tx_count": 18,
                "largest": [
                    {
                        "name": "Costco",
                        "amount": 120.0,
                        "date": "2026-02-10",
                        "category": "Shopping",
                    },
                    {"name": "Cafe", "amount": 30.0, "date": "2026-02-10", "category": "Food"},
                ],
                "categories": {"Food": 250.0, "Shopping": 150.0},
            },
            "2026-03": {
                "income": 1800.0,
                "expenses": 620.0,
                "tx_count": 30,
                "expense_tx_count": 27,
                "largest": [
                    {"name": "Ikea", "amount": 300.0, "date": "2026-03-10", "category": "Shopping"},
                    {"name": "Sushi", "amount": 80.0, "date": "2026-03-10", "category": "Food"},
                ],
                "categories": {"Food": 200.0, "Shopping": 420.0},
            },
            "2026-04": {
                "income": 2000.0,
                "expenses": 900.0,
                "tx_count": 40,
                "expense_tx_count": 36,
                "largest": [
                    {
                        "name": "Apple",
                        "amount": 450.0,
                        "date": "2026-04-10",
                        "category": "Shopping",
                    },
                    {"name": "Hot Pot", "amount": 160.0, "date": "2026-04-10", "category": "Food"},
                ],
                "categories": {"Food": 300.0, "Shopping": 600.0},
            },
            "2026-05": {
                "income": 900.0,
                "expenses": 310.0,
                "tx_count": 10,
                "expense_tx_count": 9,
                "largest": [
                    {"name": "Shoes", "amount": 90.0, "date": "2026-05-10", "category": "Shopping"}
                ],
                "categories": {"Food": 210.0, "Shopping": 100.0},
            },
        },
    }


def days_summary(today):
    """Daily totals for the 30 days up to `today`, $10 and 2 transactions a day."""
    summary = months_summary()
    summary["day_index_recent"] = {
        (today - dt.timedelta(days=n)).isoformat(): {"expenses": 10.0, "tx_count": 2}
        for n in range(30)
    }
    return summary


class PeriodRangeTestCase(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ, {"AI_ROUTER_V2_ENABLED": "1"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def ask(self, prompt, summary=None):
        service = ChatService(
            generate_reply=lambda _prompt, generation_config=None: "NONE",
            get_detailed_snapshot=lambda _uid: "",
        )
        return service.handle_chat(
            {"prompt": prompt, "history": [], "spending_summary": summary or months_summary()},
            user_id="demo-user",
        )


class CountAndDailyAverageTests(PeriodRangeTestCase):
    def test_transaction_count_adds_up_the_months(self):
        reply = self.ask("How many transactions did I make in the last 3 months?")["reply"]
        self.assertIn("From 2026-02 to 2026-04", reply)
        self.assertIn("90 transactions, 81 of them spending", reply)
        since = self.ask("How many transactions did I make since March?")["reply"]
        self.assertIn("From 2026-03 to 2026-05", since)
        self.assertIn("80 transactions", since)

    def test_daily_average_over_the_months(self):
        reply = self.ask("What's my average daily spending between February and April?")["reply"]
        # $400 + $620 + $900 over 28 + 31 + 30 days
        self.assertIn("about $22 a day ($1,920 over 89 days)", reply)

    def test_runs_of_days_use_the_daily_totals(self):
        summary = days_summary(dt.date.today())
        count = self.ask("How many transactions did I make over the past 2 weeks?", summary)
        self.assertIn("across 28 transactions", count["reply"])
        average = self.ask("What's my average daily spending in the last 10 days?", summary)
        self.assertIn("about $10 a day", average["reply"])
        self.assertIn("($100 over 10 days)", average["reply"])

    def test_runs_of_days_say_they_cant_split_a_category(self):
        summary = days_summary(dt.date.today())
        for prompt in [
            "What's my average daily food spending in the last 10 days?",
            "How many transactions did I make on food this week?",
        ]:
            with self.subTest(prompt=prompt):
                reply = self.ask(prompt, summary)["reply"]
                self.assertIn("can't split", reply)


class TopCategoryAndBiggestPurchaseTests(PeriodRangeTestCase):
    def test_top_category_adds_up_the_months(self):
        reply = self.ask("What was my top spending category in the last 3 months?")["reply"]
        # Shopping 150 + 420 + 600 beats Food 250 + 200 + 300
        self.assertIn("From 2026-02 to 2026-04", reply)
        self.assertIn("Shopping at about $1,170", reply)
        since = self.ask("What did I spend the most on since March?")["reply"]
        self.assertIn("From 2026-03 to 2026-05", since)

    def test_biggest_purchase_across_the_months(self):
        reply = self.ask("What was my biggest purchase in the last 3 months?")["reply"]
        self.assertIn("from 2026-02 to 2026-04 was Apple at $450.00", reply)
        self.assertIn("Next: Ikea at $300.00", reply)
        between = self.ask("What was my biggest purchase between February and March?")["reply"]
        self.assertIn("from 2026-02 to 2026-03 was Ikea at $300.00", between)
        food = self.ask("What was my biggest food purchase since March?")["reply"]
        self.assertIn("Hot Pot at $160.00", food)

    def test_category_pick_only_when_surely_the_biggest(self):
        summary = months_summary()
        summary["month_index"]["2026-03"]["largest"] = [
            {"name": n, "amount": a, "date": "2026-03-01", "category": "Shopping"}
            for n, a in (("A", 500.0), ("B", 400.0), ("C", 300.0))
        ]
        # a Food purchase under $300 in March could be hidden behind the top three
        reply = self.ask("What was my biggest food purchase in the last 3 months?", summary)
        self.assertNotIn("Hot Pot", reply["reply"])
        self.assertIn("can't pick your biggest single purchase", reply["reply"])

    def test_highest_expense_month_is_not_a_purchase(self):
        reply = self.ask("Which was my highest expense month in the last 3 months?")["reply"]
        self.assertIn("Highest was 2026-04 ($900)", reply)


class PastFewMonthsTests(PeriodRangeTestCase):
    def test_past_few_months_is_the_last_three_full_months(self):
        reply = self.ask("How much did I spend in the past few months?")["reply"]
        self.assertIn("$400 in 2026-02, $620 in 2026-03, $900 in 2026-04", reply)


if __name__ == "__main__":
    unittest.main()
