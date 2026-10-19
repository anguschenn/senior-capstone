"""'may' is both a month and a common verb; it only means May in a clear month context."""

import unittest

from ai.chat_service import ChatService
from ai.time_parsing import extract_period, extract_specific_date_key, extract_specific_month_key


class MayIsAVerbTests(unittest.TestCase):
    def test_verb_may_does_not_beat_a_real_month(self):
        for text in (
            "what may I have spent in june",
            "May I see what I spent in june 2026?",
            "how much may i have spent on food in June",
        ):
            with self.subTest(text):
                self.assertEqual(extract_specific_month_key(text, 2026), "2026-06")
                self.assertEqual(extract_period(text.lower()), ("month", "2026-06"))

    def test_verb_may_alone_is_not_a_month(self):
        for text in ("what may i have spent", "may i ask about my budget"):
            with self.subTest(text):
                self.assertEqual(extract_specific_month_key(text, 2026), "")
                self.assertNotEqual(extract_period(text)[0], "month")

    def test_may_in_month_context_is_still_may(self):
        for text in (
            "how much did i spend in may",
            "spending for may 2026",
            "what did i spend may 5",
            "may 2026 groceries",
            "spending during may",
            "april and may",
        ):
            with self.subTest(text):
                expected_month = "2026-04" if text.startswith("april") else "2026-05"
                self.assertEqual(extract_specific_month_key(text, 2026), expected_month)
                self.assertEqual(extract_period(text)[0], "month")
        self.assertEqual(extract_period("how much did i spend in may 2025"), ("month", "2025-05"))
        self.assertEqual(extract_specific_date_key("what did i spend may 5", 2026), "2026-05-05")

    def test_compare_fallback_skips_verb_may(self):
        service = ChatService(
            generate_reply=lambda prompt, generation_config=None: "",
            get_detailed_snapshot=lambda user_id: "",
        )
        self.assertEqual(
            service._extract_compare_periods_from_message(
                "may I compare june and july 2026 spending"
            ),
            ("2026-06", "2026-07"),
        )


if __name__ == "__main__":
    unittest.main()
