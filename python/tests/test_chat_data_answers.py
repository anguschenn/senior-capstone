"""Answers that need more than the monthly totals: spending per merchant, purchases per
category, and the Subs tab's recurring charges, all carried in the server's summary."""

import datetime as dt
import os
import unittest
from unittest import mock

from ai import server_summary
from ai.chat_service import ChatService
from ai.query_executors_v2 import matching_merchants
from ai.response_utils import short_name
from ai.validators import sanitize_spending_summary


def row(n, day, name, amount, primary, detailed, merchant=None):
    return {
        "plaid_transaction_id": f"tx-{n}",
        "plaid_account_id": "acc-card",
        "amount": amount,
        "date": day,
        "name": name,
        "merchant_name": merchant,
        "pfc_primary": primary,
        "pfc_detailed": detailed,
        "category": None,
        "pfc_confidence": "high",
        "pending": False,
    }


ROWS = [
    row(
        1,
        "2026-04-03",
        "COSTCO WHSE #123",
        120.0,
        "GENERAL_MERCHANDISE",
        "GENERAL_MERCHANDISE_SUPERSTORES",
        "Costco",
    ),
    row(
        2,
        "2026-04-20",
        "COSTCO WHSE #123",
        80.0,
        "GENERAL_MERCHANDISE",
        "GENERAL_MERCHANDISE_SUPERSTORES",
        "Costco",
    ),
    row(
        3,
        "2026-05-02",
        "COSTCO WHSE #123",
        50.0,
        "GENERAL_MERCHANDISE",
        "GENERAL_MERCHANDISE_SUPERSTORES",
        "Costco",
    ),
    row(
        4,
        "2026-05-09",
        "COSTCO WHSE #123",
        -20.0,
        "GENERAL_MERCHANDISE",
        "GENERAL_MERCHANDISE_SUPERSTORES",
        "Costco",
    ),
    row(
        5, "2026-04-05", "TST* PARIS BAGUETTE - BRO", 8.5, "FOOD_AND_DRINK", "FOOD_AND_DRINK_COFFEE"
    ),
    row(
        6, "2026-05-06", "TST* PARIS BAGUETTE - BRO", 9.5, "FOOD_AND_DRINK", "FOOD_AND_DRINK_COFFEE"
    ),
    row(
        7,
        "2026-05-07",
        "McDonald's",
        11.0,
        "FOOD_AND_DRINK",
        "FOOD_AND_DRINK_FAST_FOOD",
        "McDonald's",
    ),
    row(
        8,
        "2026-04-11",
        "UBER *TRIP",
        25.0,
        "TRANSPORTATION",
        "TRANSPORTATION_TAXIS_AND_RIDE_SHARES",
        "Uber",
    ),
    row(
        9,
        "2026-05-12",
        "UBER EATS",
        30.0,
        "FOOD_AND_DRINK",
        "FOOD_AND_DRINK_RESTAURANT",
        "Uber Eats",
    ),
    # money in, on the checking account
    row(10, "2026-04-01", "ACME PAYROLL", -2000.0, "INCOME", "INCOME_WAGES"),
    row(11, "2026-05-01", "ACME PAYROLL", -2000.0, "INCOME", "INCOME_WAGES"),
    row(
        12,
        "2026-05-03",
        "Zelle payment from ALICE HUANG 290677128",
        -50.0,
        "TRANSFER_IN",
        "TRANSFER_IN_ACCOUNT_TRANSFER",
    ),
    row(
        13,
        "2026-05-10",
        "Zelle payment from Ryan Cao COFJGHAMBWMY",
        -30.0,
        "TRANSFER_IN",
        "TRANSFER_IN_ACCOUNT_TRANSFER",
    ),
]
for r in ROWS[-4:]:
    r["plaid_account_id"] = "acc-checking"
ACCOUNTS = {
    "acc-card": {
        "plaid_account_id": "acc-card",
        "name": "Card",
        "account_type": "credit",
        "subtype": "credit card",
    },
    "acc-checking": {
        "plaid_account_id": "acc-checking",
        "name": "Checking",
        "account_type": "depository",
        "subtype": "checking",
    },
}
SUBSCRIPTIONS = [
    {
        "name": "Spotify",
        "amount": 11.99,
        "frequency": "monthly",
        "next_charge": "2026-05-18",
        "unconfirmed": False,
    },
    {
        "name": "Gym Pass",
        "amount": 120.0,
        "frequency": "yearly",
        "next_charge": "2026-09-01",
        "unconfirmed": True,
    },
]


def build():
    txs = server_summary.build_transactions(ROWS, ACCOUNTS, {}, None, {})
    summary = server_summary.build_summary(
        txs,
        [],
        now=dt.datetime(2026, 5, 20, 12),
        focus_month="2026-05",
        all_year=False,
        all_accounts=True,
        scope_label="Overall (All Accounts)",
        tz_name="",
    )
    summary["merchant_index"], summary["category_counts"] = server_summary.spending_detail(txs)
    summary["income_index"] = server_summary.income_detail(txs)
    summary["subscriptions"] = SUBSCRIPTIONS
    return summary


class SpendingDetailTests(unittest.TestCase):
    def test_merchants_add_up_like_the_month_totals(self):
        summary = build()
        index = summary["merchant_index"]
        # the refund lowers Costco in May: 50 - 20
        self.assertEqual(index["Costco"]["months"]["2026-05"], {"spent": 30.0, "count": 1})
        self.assertEqual(index["Costco"]["months"]["2026-04"], {"spent": 200.0, "count": 2})
        for month in ("2026-04", "2026-05"):
            merchants = sum(e["months"].get(month, {}).get("spent", 0) for e in index.values())
            self.assertAlmostEqual(merchants, summary["month_index"][month]["expenses"])

    def test_payers_add_up_like_the_month_income(self):
        summary = build()
        index = summary["income_index"]
        for month in ("2026-04", "2026-05"):
            payers = sum(e["months"].get(month, {}).get("received", 0) for e in index.values())
            self.assertAlmostEqual(payers, summary["month_index"][month]["income"])
        self.assertNotIn("Costco", index)  # its refund is money back, not income
        # payers are named without the bank's reference numbers
        self.assertIn("Zelle payment from ALICE HUANG", index)
        self.assertIn("Zelle payment from Ryan Cao", index)

    def test_short_names_drop_bank_references(self):
        for name, short in [
            ("ATM CASH DEPOSIT 10/12 5423 8TH AVE", "ATM CASH DEPOSIT"),
            ("Zelle payment from Ryan Cao COFJGHAMBWMY", "Zelle payment from Ryan Cao"),
            ("172355 CLASSLINK PAYROLL PPD ID: 1364227403", "CLASSLINK PAYROLL"),
            ("REMOTE ONLINE DEPOSIT # 1", "REMOTE ONLINE DEPOSIT"),
            ("Zelle payment from CHRISTOPHER", "Zelle payment from CHRISTOPHER"),
            ("7-Eleven 34567", "7-Eleven"),
            ("99 Ranch Market", "99 Ranch Market"),
            ("Pier 1 Imports", "Pier 1 Imports"),
            ("Trader Joe's #552", "Trader Joe's"),
            ("McDonald's", "McDonald's"),
        ]:
            with self.subTest(name=name):
                self.assertEqual(short_name(name), short)

    def test_purchases_per_category(self):
        may = build()["category_counts"]["2026-05"]
        # Costco (the refund isn't a purchase), Paris Baguette, McDonald's, Uber Eats
        self.assertEqual(may, {"Food": 3, "Shopping": 1})

    def test_names_match_at_word_starts_whatever_the_punctuation(self):
        index = build()["merchant_index"]
        self.assertEqual(matching_merchants("mcdonalds", index), ["McDonald's"])
        self.assertEqual(matching_merchants("paris baguette", index), ["TST* PARIS BAGUETTE - BRO"])
        self.assertEqual(sorted(matching_merchants("uber", index)), ["Uber", "Uber Eats"])
        self.assertEqual(matching_merchants("eats", index), ["Uber Eats"])
        self.assertEqual(matching_merchants("co", index), [])  # too short to mean one

    def test_the_sanitizer_keeps_them(self):
        cleaned = sanitize_spending_summary(build())
        self.assertIn("Costco", cleaned["merchant_index"])
        self.assertEqual(cleaned["subscriptions"][0]["name"], "Spotify")
        self.assertTrue(cleaned["category_counts"]["2026-04"])


class ChatAnswerTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ, {"AI_ROUTER_V2_ENABLED": "1"})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.summary = build()
        self.service = ChatService(
            generate_reply=lambda _prompt, generation_config=None: "NONE",
            get_detailed_snapshot=lambda _uid: "",
        )

    def ask(self, prompt):
        return self.service.handle_chat(
            {"prompt": prompt, "history": [], "spending_summary": self.summary}, user_id="u"
        )["reply"]

    def test_merchant_totals_for_the_period_asked(self):
        self.assertEqual(
            self.ask("How much did I spend at Costco?"),
            "You spent $230.00 at Costco from 2026-04 to 2026-05, across 3 purchases. "
            "By month: 2026-04 $200, 2026-05 $30.",
        )
        self.assertIn(
            "$200.00 at Costco in 2026-04", self.ask("How much did I spend at Costco in April?")
        )
        self.assertIn(
            "$9.50 at TST* PARIS BAGUETTE - BRO in 2026-05",
            self.ask("How much did I spend at Paris Baguette this month?"),
        )

    def test_a_merchant_the_rules_read_as_a_category(self):
        reply = self.ask("How much did I spend on Uber this month?")
        self.assertIn("$30.00 at Uber (Uber Eats and Uber) in 2026-05", reply)
        self.assertNotIn("isn't tracked separately", reply)

    def test_merchant_yes_no_when_and_days(self):
        self.assertTrue(
            self.ask("Did I spend anything at McDonald's last month?").startswith("No. ")
        )
        self.assertIn(
            "Your last purchase at Costco was in 2026-05", self.ask("When did I last pay Costco?")
        )
        self.assertIn(
            "not by day", self.ask("How much did I spend at Costco over the past 2 weeks?")
        )
        self.assertIn(
            "I don't see any charges from Walmart", self.ask("How much did I spend at Walmart?")
        )

    def test_purchases_in_a_category(self):
        reply = self.ask("How many times did I buy food this month?")
        self.assertIn("made 3 Food purchases, about $50", reply)  # Costco is Shopping

    def test_subscriptions(self):
        listed = self.ask("What subscriptions do I have?")
        # $11.99 a month plus $120 a year
        self.assertIn("You have 2 active subscriptions, about $21.99 a month", listed)
        self.assertIn("Gym Pass $120.00 yearly (next Sep 1, not confirmed yet)", listed)
        self.assertEqual(
            self.ask("When does Spotify renew?"),
            "Spotify renews on 2026-05-18 for $11.99 (monthly).",
        )
        self.assertIn(
            "about $21.99 a month", self.ask("How much do my subscriptions cost per month?")
        )
        # spending in a past month stays the category total
        self.assertNotIn(
            "active subscriptions", self.ask("How much did I spend on subscriptions last month?")
        )
        self.assertNotIn(
            "active subscriptions", self.ask("What subscriptions did I have in April?")
        )
        self.assertIn(
            "isn't among the active recurring charges", self.ask("When does Netflix renew?")
        )
        # a past charge, not the next renewal
        self.assertNotIn("renews on", self.ask("When was Spotify charged last?"))

    def test_money_received_from_a_payer(self):
        self.assertEqual(
            self.ask("How much did I get from ACME last month?"),
            "Your income from ACME PAYROLL in 2026-04 was $2,000.00, across 1 deposit. "
            "That's 100% of your income in 2026-04.",
        )
        zelle = self.ask("How much did I receive from Zelle this month?")
        self.assertIn("Your income from Zelle (Zelle payment from ALICE HUANG", zelle)
        self.assertIn("was $80.00, across 2 deposits", zelle)
        self.assertIn("$50.00", self.ask("How much did Alice send me this month?"))
        self.assertTrue(self.ask("Did ACME pay me in April?").startswith("Yes. "))
        self.assertIn("in 2026-05", self.ask("When did I last get money from ACME?"))
        self.assertIn(
            "I don't see any money received from Walmart",
            self.ask("How much did I receive from Walmart?"),
        )
        # a general source is the income total, and a payback isn't income
        self.assertNotIn("Your income from", self.ask("How much did I earn from work last month?"))
        self.assertNotIn("Your income from", self.ask("Did Alice pay me back?"))

    def test_money_received_and_plain_words_are_not_merchants(self):
        received = self.ask("How much did I receive from Uber last month?")
        self.assertNotIn("at Uber", received)
        self.assertIn("I don't see any money received from Uber", received)
        goal = self.ask("How much do I need to save to hit my target this month?")
        self.assertNotIn("You spent", goal)


if __name__ == "__main__":
    unittest.main()
