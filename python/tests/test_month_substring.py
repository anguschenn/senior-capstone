"""Month detection in ChatService must match whole month words, not substrings."""

import unittest

from ai.chat_service import ChatService


def _service():
    return ChatService(
        generate_reply=lambda prompt, generation_config=None: "",
        get_detailed_snapshot=lambda user_id: "",
    )


class MonthSubstringTests(unittest.TestCase):
    def test_words_containing_month_names_are_not_months(self):
        # "may" (verb), "mar" in "market", "oct" in "doctor", "dec" in "decide".
        for text in (
            "what may I spend",
            "how much did I spend at the market",
            "how much did I spend at the doctor",
            "help me decide what to spend",
        ):
            with self.subTest(text):
                self.assertEqual(_service()._timeframe_mode(text), "unknown")

    def test_real_month_names_still_count(self):
        for text in ("how much did I spend in june", "spending for may 2026"):
            with self.subTest(text):
                self.assertEqual(_service()._timeframe_mode(text), "annual_year")

    def test_asks_amount_ignores_month_substrings(self):
        service = _service()
        self.assertFalse(service._asks_amount("should I spend less at the market"))
        self.assertFalse(service._asks_amount("may I spend less on food"))
        self.assertTrue(service._asks_amount("what did I spend in june"))
        self.assertTrue(service._asks_amount("spend in march"))


if __name__ == "__main__":
    unittest.main()
