import datetime as dt
import os
import unittest
from unittest import mock

from ai.asked_period import asked_period, covers, shows_other_period, week_span
from ai.chat_service import ChatService
from ai.query_parser_v2 import _normalize

SUMMARY = {
    "scope": "all_accounts",
    "scope_label": "Overall (All Accounts)",
    "time_anchor": {"selected_month": "2026-05", "selected_year": 2026},
    "month_index": {
        "2026-02": {"income": 1500.0, "expenses": 400.0, "categories": {"Food": 50.0}},
        "2026-03": {"income": 1800.0, "expenses": 1750.0, "categories": {"Food": 120.0}},
        "2026-04": {"income": 1997.75, "expenses": 1987.86, "categories": {"Food": 300.0}},
        "2026-05": {"income": 900.0, "expenses": 600.0, "categories": {"Food": 400.0}},
    },
    "budgets": {
        "month": "2026-05",
        "items": [{"category": "Food", "spent": 400.0, "limit": 300.0}],
    },
}


class AskedPeriodTests(unittest.TestCase):
    def test_reads_runs_of_months_weeks_and_days(self):
        cases = [
            ("have i been on budget for the last 3 months", "months", ("2026-02", "2026-04")),
            ("how much did i spend in the past few months", "months", ("2026-02", "2026-04")),
            ("food in the last couple of months", "months", ("2026-03", "2026-04")),
            ("spending since march", "months", ("2026-03", "2026-05")),
            ("between february and april", "months", ("2026-02", "2026-04")),
            ("how much this year", "months", ("2026-01", "2026-05")),
            ("over the past 2 weeks", "days", 14),
            ("in the last 10 days", "days", 10),
            # Monday to today
            ("this week", "days", dt.date.today().weekday() + 1),
            ("last week", "days", 7),
            ("over the past week", "days", 7),
        ]
        for text, kind, expected in cases:
            with self.subTest(text=text):
                asked = asked_period(text, SUMMARY)
                self.assertEqual(asked.kind, kind)
                if kind == "days":
                    self.assertEqual(asked.days, expected)
                else:
                    self.assertEqual((asked.months[0], asked.months[-1]), expected)

    def test_last_week_is_monday_to_sunday(self):
        wednesday = dt.date(2026, 11, 4)
        self.assertEqual(
            week_span("last", wednesday), (dt.date(2026, 10, 26), dt.date(2026, 11, 1))
        )
        self.assertEqual(week_span("this", wednesday), (dt.date(2026, 11, 2), wednesday))
        # on a Monday, this week is that one day and last week ended yesterday
        monday = dt.date(2026, 11, 2)
        self.assertEqual(week_span("this", monday), (monday, monday))
        self.assertEqual(week_span("last", monday)[1], dt.date(2026, 11, 1))
        asked = asked_period("how much did i spend last week", SUMMARY)
        self.assertEqual(asked.last_day, week_span("last")[1])
        # an answer about the last 7 days isn't about last week
        last_7 = {"reply": "Over the last 7 days, you spent about $90.", "period_resolved": ""}
        if dt.date.today().weekday() != 6:
            self.assertFalse(covers(asked, last_7, SUMMARY))
        first, last = week_span("last")
        week = {"reply": "", "period_resolved": f"{first} to {last}"}
        self.assertTrue(covers(asked, week, SUMMARY))

    def test_other_wordings_read_as_runs_of_months(self):
        cases = [
            ("have i been on budget for the last half year", ("2025-11", "2026-04")),
            ("spending in the past half-year", ("2025-11", "2026-04")),
            ("spending in the past year", ("2025-05", "2026-04")),
            ("food in the past 6 month", ("2025-11", "2026-04")),
            ("since the start of the year", ("2026-01", "2026-05")),
            ("over the last couple of quarters", ("2025-11", "2026-04")),
        ]
        for text, expected in cases:
            with self.subTest(text=text):
                asked = asked_period(_normalize(text), SUMMARY)
                self.assertEqual((asked.months[0], asked.months[-1]), expected)
        # these keep their own meanings
        for text in [
            "spending last year",
            "the first half of the year",
            "second half of the year",
            "how much will i have saved in half a year",
        ]:
            with self.subTest(text=text):
                self.assertIsNone(asked_period(_normalize(text), SUMMARY))

    def test_single_months_and_no_period_are_not_runs(self):
        for text in ["this month", "in april", "last month", "how much did i spend", "since may"]:
            with self.subTest(text=text):
                self.assertIsNone(asked_period(text, SUMMARY))

    def test_label_reads_after_a_verb(self):
        self.assertEqual(asked_period("the last 3 months", SUMMARY).label, "for the last 3 months")
        self.assertEqual(asked_period("since march", SUMMARY).label, "since March")
        self.assertEqual(asked_period("this week", SUMMARY).label, "for this week")

    def test_covers_matches_the_answer_to_the_period(self):
        three = asked_period("the last 3 months", SUMMARY)
        self.assertTrue(covers(three, {"period_resolved": "2026-02, 2026-03, 2026-04"}, SUMMARY))
        # the other reading of "the last 3 months" (ending this month) counts too
        self.assertTrue(covers(three, {"period_resolved": "2026-03 to 2026-05"}, SUMMARY))
        self.assertFalse(
            covers(three, {"period_resolved": "2026-05", "reply": "For 2026-05"}, SUMMARY)
        )
        weeks = asked_period("the past 2 weeks", SUMMARY)
        today = dt.date(2026, 5, 17)
        fortnight = {"reply": "From 2026-05-04 to 2026-05-17, you spent"}
        self.assertTrue(covers(weeks, fortnight, SUMMARY, today=today))
        # 14 days, but not the 14 days ending today
        earlier = {"reply": "From 2026-03-01 to 2026-03-14, you spent"}
        self.assertFalse(covers(weeks, earlier, SUMMARY, today=today))
        self.assertFalse(covers(weeks, {"period_resolved": "2026-05"}, SUMMARY, today=today))
        year = asked_period("this year", SUMMARY)
        self.assertTrue(covers(year, {"reply": "For 2026, total recorded expenses"}, SUMMARY))
        # months with no data and the month still running may be left out
        self.assertTrue(covers(year, {"period_resolved": "2026-02 to 2026-04"}, SUMMARY))
        span = asked_period("did it go up from february to may", SUMMARY)
        self.assertTrue(covers(span, {"period_resolved": "2026-05 vs 2026-02"}, SUMMARY))

    def test_covers_does_not_accept_too_few_months(self):
        # "the last 2 months" ending this month is April and May; April alone is short
        two = asked_period("the last 2 months", SUMMARY)
        self.assertFalse(
            covers(two, {"period_resolved": "2026-04", "reply": "In 2026-04"}, SUMMARY)
        )
        # no data in the months asked: an answer about another month doesn't count
        later = dict(SUMMARY, time_anchor={"selected_month": "2026-09", "selected_year": 2026})
        three = asked_period("the last 3 months", later)
        self.assertFalse(covers(three, {"period_resolved": "2026-05"}, later))
        self.assertTrue(covers(three, {"reply": "I don't see any spending then."}, later))

    def test_shows_other_period(self):
        weeks = asked_period("last week", SUMMARY)
        self.assertTrue(shows_other_period(weeks, {"reply": "Your categories in 2026-05"}, SUMMARY))
        self.assertFalse(shows_other_period(weeks, {"reply": "I can't total tax."}, SUMMARY))


class OtherPeriodAnswerTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ, {"AI_ROUTER_V2_ENABLED": "1"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def _ask(self, prompt):
        service = ChatService(
            generate_reply=lambda _prompt, generation_config=None: "NONE",
            get_detailed_snapshot=lambda _uid: "",
        )
        return service.handle_chat(
            {"prompt": prompt, "history": [], "spending_summary": SUMMARY}, user_id="demo-user"
        )

    def test_says_so_instead_of_answering_another_period(self):
        response = self._ask("Was I over budget in the past 2 weeks?")
        self.assertEqual(
            response["reply"],
            "I can't answer that for the past 2 weeks yet. Ask about a single month instead, "
            'like "this month" or "in April".',
        )
        self.assertEqual(response["period_resolved"], "")
        self.assertNotIn("$400", response["reply"])

    def test_answers_that_cover_the_period_are_kept(self):
        response = self._ask("How much did I spend in the last 3 months?")
        self.assertIn("2026-02", response["reply"])
        self.assertIn("2026-04", response["reply"])
        self.assertNotIn("I can't answer that", response["reply"])

    def test_a_reply_that_says_can_t_still_may_not_show_another_period(self):
        response = self._ask("Did I have any big purchases last week?")
        self.assertTrue(response["reply"].startswith("I can't answer that for last week yet."))

    def test_each_part_of_a_multi_question_is_checked(self):
        response = self._ask(
            "How much did I spend in April? Also was I over budget in the past 2 weeks?"
        )
        self.assertIn("2026-04", response["reply"])
        self.assertIn("I can't answer that for the past 2 weeks yet.", response["reply"])

    def test_period_words_it_cant_read_are_not_answered_as_one_month(self):
        response = self._ask("Was I over budget over the last few years?")
        self.assertTrue(
            response["reply"].startswith('I\'m not sure which period "last few years" covers.'),
            response["reply"],
        )

    def test_unread_period_keeps_a_reason_already_given(self):
        response = self._ask("How much tax did I pay over the last few years?")
        self.assertIn("can't total the tax", response["reply"])

    def test_days_of_a_named_month_are_not_an_unread_run(self):
        response = self._ask("How much did I spend in the first days of April?")
        self.assertNotIn("I'm not sure which period", response["reply"])

    def test_single_month_questions_are_untouched(self):
        response = self._ask("Am I over budget this month?")
        self.assertIn("Food", response["reply"])
        self.assertNotIn("I can't answer that", response["reply"])


if __name__ == "__main__":
    unittest.main()
