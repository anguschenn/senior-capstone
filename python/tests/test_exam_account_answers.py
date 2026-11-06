"""Answers on the chat exam's made-up account (tests/exam_fixture.py, today pinned to
Monday 2026-06-15) for calendar weeks, runs of days, a named year's months, tied months, and a short
trend since a month. Expected numbers are sums over the
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


if __name__ == "__main__":
    unittest.main()
