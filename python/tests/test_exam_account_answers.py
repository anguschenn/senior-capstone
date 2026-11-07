"""Answers on the chat exam's made-up account (tests/exam_fixture.py, today pinned to
Monday 2026-06-15) for calendar weeks, a named year's months, tied months, a short trend
since a month, and money received from one payer. Expected numbers are sums over the
fixture's rows."""

import unittest

import exam_fixture

from ai.chat_service import ChatService


class ExamAccountAnswerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.summary = exam_fixture.summary()

    def setUp(self):
        exam_fixture.pin_today(self)
        self.service = ChatService(
            generate_reply=lambda _prompt, generation_config=None: "NONE",
            get_detailed_snapshot=lambda _uid: "",
        )

    def ask(self, prompt):
        return self.service.handle_chat(
            {"prompt": prompt, "history": [], "spending_summary": self.summary}, user_id="u"
        )["reply"]

    def test_last_week_is_monday_to_sunday(self):
        # June 8 to 14: lunch every day $70, Netflix $15.49, Target $60, Regal $30
        self.assertEqual(
            self.ask("How much did I spend last week?"),
            "From 2026-06-08 to 2026-06-14, you spent about $175 for Overall (All Accounts) "
            "across 10 transactions.",
        )
        compared = self.ask("How did this week compare to last week?")
        self.assertIn("This week so far (2026-06-15 to 2026-06-15)", compared)
        self.assertIn("same days last week (2026-06-08 to 2026-06-08)", compared)
        self.assertIn("Last week came to about $175 in all.", compared)
        self.assertIn(
            "2026-06-08 to 2026-06-14", self.ask("How much did I spend the previous week?")
        )
        # "the past week" and "the last week" stay the last 7 days
        self.assertIn("last 7 days", self.ask("How much did I spend in the past week?"))
        self.assertIn("last 7 days", self.ask("How much did I spend over the last week?"))

    def test_income_and_cash_flow_over_days(self):
        # June 6 to 15: pay $2,500 on the 15th; $225.49 spent
        self.assertIn(
            "received about $2,500 and spent about $225, so net cash flow is about +$2,275",
            self.ask("What was my cash flow in the last 10 days?"),
        )
        self.assertIn(
            "From 2026-06-02 to 2026-06-15, Overall (All Accounts) received about $2,500 in income",
            self.ask("What was my income over the past 2 weeks?"),
        )
        self.assertIn(
            "From 2026-06-01 to 2026-06-07", self.ask("How much did I spend the week before last?")
        )

    def test_this_week_on_a_monday_is_that_day(self):
        # this week so far is Monday June 15 alone, and still gets an answer
        for prompt in (
            "Is my spending this week normal?",
            "Did I spend anything on food this week?",
            "What's my average daily spending this week?",
        ):
            with self.subTest(prompt=prompt):
                reply = self.ask(prompt)
                self.assertIn("2026-06-15", reply)
                self.assertNotIn("I can't answer that", reply)
        self.assertIn("A usual day is about $32", self.ask("Is my spending this week normal?"))

    def test_the_week_before_last_week(self):
        first = "How much did I spend last week?"
        history = [{"role": "user", "text": first}, {"role": "assistant", "text": self.ask(first)}]
        reply = self.service.handle_chat(
            {
                "prompt": "What about the week before?",
                "history": history,
                "spending_summary": self.summary,
            },
            user_id="u",
        )["reply"]
        # June 1 to 7: lunch $70, Spotify $11.99, Uber $20
        self.assertIn("From 2026-06-01 to 2026-06-07, you spent about $102", reply)

    def test_highest_month_of_the_year_asked(self):
        self.assertIn(
            "In 2025, your month with the highest spending for Overall (All Accounts) was "
            "2025-07, at about $637.",
            self.ask("Which was my highest expense month in 2025?"),
        )
        # August, October and December 2025: $487.48 each
        self.assertIn(
            "lowest, about $487, in 3 months (2025-08, 2025-10 and 2025-12)",
            self.ask("Which month did I spend the least last year?"),
        )
        self.assertIn(
            "In 2025, your savings (income minus spending)",
            self.ask("Which month did I save the most last year?"),
        )
        self.assertIn(
            "Between 2025-12 and 2026-05, your month with the highest spending",
            self.ask("Which month did I spend the most in the last 6 months?"),
        )
        self.assertIn(
            "I don't see any months of 2024",
            self.ask("Which month did I spend the most in 2024?"),
        )

    def test_tied_months_are_named_as_a_tie(self):
        self.assertIn(
            "your income for Overall (All Accounts) was at its lowest, about $5,000, in all 6 "
            "months (2025-07 to 2025-12), so no single month stands out.",
            self.ask("Which month did I earn the least last year?"),
        )
        self.assertIn(
            "in 4 months (2026-01, 2026-03, 2026-04 and 2026-05)",
            self.ask("Which month did I earn the most this year?"),
        )

    def test_trend_since_a_recent_month_counts_this_month_at_its_pace(self):
        # June so far: $307.48 in 15 of 30 days
        reply = self.ask("Is my spending going up since April?")
        self.assertIn(
            "has been going up: 2026-04 $427, 2026-05 $637, 2026-06 on pace for about $615.",
            reply,
        )
        self.assertIn("2026-06 is 15 of 30 days in, with $307 spent so far.", reply)
        self.assertIn(
            "2026-06 so far is $5,000, already as much as 2026-05.",
            self.ask("Is my income going up since April?"),
        )

    def test_a_few_days_into_a_month_its_pace_is_left_out(self):
        exam_fixture.pin_today(self, exam_fixture.TODAY.replace(day=4))
        reply = self.ask("Is my spending going up since April?")
        # the direction comes from April and May alone
        self.assertIn("2026-04 $427, 2026-05 $637.", reply)
        self.assertIn("2026-06 is only 4 of 30 days in", reply)
        self.assertNotIn("on pace", reply)
        self.assertIn(
            "too early in 2026-06 to tell", self.ask("Is my spending going up since May?")
        )

    def test_money_received_from_a_payer(self):
        # pay on the 1st and 15th, only the 1st in February
        self.assertIn(
            "Your income from ACME PAYROLL from 2026-01 to 2026-06 was $27,500.00, across 11 "
            "deposits.",
            self.ask("How much did I get from ACME this year?"),
        )
        self.assertIn(
            "I don't see any money received from Zelle",
            self.ask("How much did I receive from Zelle last month?"),
        )
        # where all the pay comes from is the income total
        self.assertIn("total income", self.ask("How much did I earn from my day job last month?"))

    def test_since_a_weekday_and_last_weekend(self):
        # Monday June 15: lunch $10 and Uber $20
        self.assertIn(
            "On 2026-06-15, you spent about $30", self.ask("How much have I spent since Monday?")
        )
        # June 8 to 15: lunch $80, Netflix $15.49, Target $60, Regal $30, Uber $20
        self.assertIn(
            "From 2026-06-08 to 2026-06-15, you spent about $205",
            self.ask("How much have I spent since last Monday?"),
        )
        # on Saturday June 13, last weekend is June 6 and 7: lunch alone
        exam_fixture.pin_today(self, exam_fixture.TODAY.replace(day=13))
        self.assertIn(
            "From 2026-06-06 to 2026-06-07, you spent about $20",
            self.ask("How much did I spend last weekend?"),
        )
        # after the latest transaction (June 15), there's nothing to count yet
        exam_fixture.pin_today(self, exam_fixture.TODAY.replace(day=17))
        self.assertIn(
            "Your latest synced transaction is from 2026-06-15",
            self.ask("How much did I spend yesterday?"),
        )

    def test_a_follow_up_about_that_keeps_its_period(self):
        first = "How much did I spend in April?"
        history = [{"role": "user", "text": first}, {"role": "assistant", "text": self.ask(first)}]
        reply = self.service.handle_chat(
            {
                "prompt": "How much of that was shopping?",
                "history": history,
                "spending_summary": self.summary,
            },
            user_id="u",
        )["reply"]
        # Target $60 less the $50 Costco refund, of April's $427.48
        self.assertIn("In 2026-04, Shopping was about $10", reply)

        first = "How much did I spend last week?"
        history = [{"role": "user", "text": first}, {"role": "assistant", "text": self.ask(first)}]
        reply = self.service.handle_chat(
            {
                "prompt": "How much of that was food?",
                "history": history,
                "spending_summary": self.summary,
            },
            user_id="u",
        )["reply"]
        # a week can't be split by category: say so, with the week's total
        self.assertIn("can't split 2026-06-08 to 2026-06-14 by category", reply)
        self.assertIn("about $175 in total", reply)

    def test_rankings(self):
        self.assertIn(
            "Your biggest expense from 2025-07 to 2026-06 was Apple Store at $1,200.00",
            self.ask("What's my biggest purchase ever?"),
        )
        self.assertIn(
            "the most expensive is Netflix $15.49",
            self.ask("What's my most expensive subscription?"),
        )
        # pay on the 1st and 15th from July 2025, only the 1st in February
        self.assertIn(
            "most of your income came from ACME PAYROLL $57,500 (23 deposits). That covers 100%",
            self.ask("Who sends me the most money?"),
        )
        # lunch every day for 350 days; Costco 6 x $150 less the $50 refund
        self.assertIn(
            "Corner Deli $3,500 (350 purchases), Apple Store $1,200 (1 purchase), Costco $850",
            self.ask("Where do I shop the most?"),
        )
        self.assertIn(
            "by purchases were Corner Deli $3,500 (350 purchases), Uber $700 (35 purchases)",
            self.ask("Which store do I go to most often?"),
        )

        self.assertIn(
            "the most expensive is Netflix", self.ask("Which subscription costs the most?")
        )
        # "where do I spend" is categories, not stores
        self.assertNotIn("merchants", self.ask("Where do I spend the most money?"))
        # a payer under half of the income is the biggest source, not "most of it"
        summary = {
            **self.summary,
            "income_index": {
                "ACME PAYROLL": {"months": {"2026-05": {"received": 2000.0, "count": 1}}},
                "Venmo": {"months": {"2026-05": {"received": 1500.0, "count": 3}}},
                "Zelle payment from ALICE": {
                    "months": {"2026-05": {"received": 1500.0, "count": 2}}
                },
            },
        }
        reply = self.service.handle_chat(
            {"prompt": "Who paid me the most in May?", "history": [], "spending_summary": summary},
            user_id="u",
        )["reply"]
        self.assertIn("your biggest source of income was ACME PAYROLL $2,000", reply)

    def test_merchants_counts_and_slang(self):
        self.assertTrue(
            self.ask("Did I spend anything at Walmart last month?").startswith(
                "No. I don't see any charges from Walmart"
            )
        )
        self.assertIn("You spent $92.94 at Netflix", self.ask("netflix this year"))
        self.assertIn("made 31 Food purchases", self.ask("How many times did I eat out in May?"))
        self.assertIn("about $637", self.ask("How much did I blow last month?"))

        self.assertTrue(
            self.ask("Did I make any purchases at the Apple Store in March?").startswith(
                "Yes. You spent $1,200.00 at Apple Store in 2026-03"
            )
        )

    def test_yes_or_no_and_no_stray_notes(self):
        # June so far: Food $150 of $305 (on pace for $300); Transport $40 of $65 (pace $80)
        self.assertTrue(self.ask("Will I go over my food budget this month?").startswith("No. "))
        self.assertTrue(
            self.ask("Will I go over my transport budget this month?").startswith("Yes. ")
        )
        # this week $30 (Monday) against $25.49 last Monday
        self.assertTrue(self.ask("Did I spend more this week than last week?").startswith("Yes. "))
        for prompt in (
            "How much budget do I have left for food?",
            "How many days in May did I not spend anything?",
        ):
            with self.subTest(prompt=prompt):
                self.assertNotIn("doesn't cover", self.ask(prompt))

        # a threshold isn't a day with no spending
        self.assertNotIn(
            "had no spending", self.ask("How many days did I not spend more than $50 in May?")
        )

    def test_cash_deposits_are_a_payer(self):
        summary = {
            **self.summary,
            "income_index": {
                **self.summary["income_index"],
                "ATM CASH DEPOSIT": {"months": {"2026-05": {"received": 300.0, "count": 1}}},
            },
        }
        reply = self.service.handle_chat(
            {
                "prompt": "How much cash did I deposit last month?",
                "history": [],
                "spending_summary": summary,
            },
            user_id="u",
        )["reply"]
        self.assertIn("Your income from ATM CASH DEPOSIT in 2026-05 was $300.00", reply)

    def test_making_a_purchase_is_spending(self):
        self.assertTrue(
            self.ask("Did I make any purchases at Costco in April?").startswith(
                "No. You didn't spend anything at Costco in 2026-04."
            )
        )
        self.assertNotIn("income", self.ask("Did I make a purchase from Amazon?"))


if __name__ == "__main__":
    unittest.main()
