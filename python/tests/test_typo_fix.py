import unittest

from ai.typo_fix import fix_typos


class TypoFixTests(unittest.TestCase):
    def test_common_misspellings_are_corrected(self):
        cases = {
            "hw much did i spedn on fod in octobr": "how much did i spent on food in october",
            "wat was my incom lst month": "what was my income last month",
            "how mcuh did I spnd on transprot last mnth?": (
                "how much did i spend on transport last month?"
            ),
            "list my lst 5 transactons": "list my last 5 transactions",
            "whats my net cashflow": "what is my net cash flow",
        }
        for typed, expected in cases.items():
            with self.subTest(typed=typed):
                self.assertEqual(fix_typos(typed), expected)

    def test_real_words_and_merchants_are_left_alone(self):
        for text in (
            "same as last month at costco",
            "did i blow too much cash on eating out",
            "spotify netflix uber gym",
            "is october worse than september",
            "how much have i saved this year",
            "is my spending healthy",
            "showing what i budgeted",
            "it feels like i spend a lot",
            "which category did i spend the least on",
        ):
            with self.subTest(text=text):
                self.assertEqual(fix_typos(text), text)
