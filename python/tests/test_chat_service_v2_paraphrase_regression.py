import os
import unittest

from ai.chat_service import ChatService


class TestChatServiceV2ParaphraseRegression(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        os.environ["AI_ROUTER_V2_ENABLED"] = "1"

    def _service(self):
        def generate_reply(_prompt, generation_config=None):
            _ = generation_config
            return '{"reply":"model"}'

        return ChatService(generate_reply=generate_reply, get_detailed_snapshot=lambda _uid: "")

    def _summary(self):
        return {
            "scope": "all_accounts",
            "scope_label": "Overall (All Accounts)",
            "time_anchor": {"selected_month": "2026-05", "selected_year": 2026},
            "month_index": {
                "2026-05": {
                    "income": 2100.0,
                    "expenses": 2020.0,
                    "tx_count": 22,
                    "expense_tx_count": 17,
                    "top_category": {"name": "Food", "amount": 160},
                },
                "2026-04": {
                    "income": 1997.75,
                    "expenses": 1987.86,
                    "tx_count": 20,
                    "expense_tx_count": 16,
                    "top_category": {"name": "Subscriptions", "amount": 131},
                },
                "2026-03": {
                    "income": 1800.0,
                    "expenses": 1750.0,
                    "tx_count": 18,
                    "expense_tx_count": 14,
                    "top_category": {"name": "Food", "amount": 120},
                },
            },
            "recent_transactions": [
                {"date": "2026-05-08", "name": "Netflix", "amount": -15.99},
                {"date": "2026-05-07", "name": "Uber", "amount": -12.50},
                {"date": "2026-05-06", "name": "Spotify", "amount": -10.99},
            ],
            "totals": {"tx_count_30d": 22, "income_30d": 3898, "expenses_30d": 3842},
            "year_index": {
                "2026": {"income": 9500.0, "expenses": 9100.0},
                "2025": {"income": 8700.0, "expenses": 8200.0},
            },
        }

    def _ask(self, prompt):
        svc = self._service()
        return svc.handle_chat(
            {"prompt": prompt, "history": [], "spending_summary": self._summary()},
            user_id="demo-user",
        )

    def test_explain_last_month_paraphrase_family(self):
        prompts = [
            "why did my spending increase last month",
            "what caused my spending to go up last month",
            "what caused my spending to go up previous month",
            "why did my spending increase prior month",
            "why was spending higher past month",
            "why did my spending increase last mo",
            "why is last month spending higher",
            "help me understand why spending grew last month",
            "what made my expenses rise last month",
            "why was I spending more last month",
            "what drove my spending up last month",
            "last month spending went up, why",
            "why did i spend more last month",
            "what's behind my higher spending last month",
        ]
        for prompt in prompts:
            with self.subTest(prompt=prompt):
                response = self._ask(prompt)
                self.assertEqual(response["intent"], "explain")
                self.assertEqual(response["answer_source"], "deterministic")
                self.assertEqual(response.get("period_resolved"), "2026-04 vs 2026-03")
                self.assertIn("month_index.expenses", response.get("facts_used", []))

    def test_top_category_last_month_paraphrase_family(self):
        prompts = [
            "top category last month",
            "top category previous month",
            "top category prior month",
            "top category last mo",
            "what did I spend most on last month",
            "highest spending category last month",
            "what category took the most money last month",
            "which category was highest last month",
            "last month what category did i spend the most",
            "biggest category in my spending last month",
            "show my #1 spend category last month",
            "highest spend category last month",
        ]
        for prompt in prompts:
            with self.subTest(prompt=prompt):
                response = self._ask(prompt)
                self.assertEqual(response["intent"], "top_category_lookup")
                self.assertEqual(response["answer_source"], "deterministic")
                self.assertEqual(response.get("period_resolved"), "2026-04")
                self.assertIn("month_index.top_category", response.get("facts_used", []))

    def test_recent_transactions_paraphrase_family(self):
        prompts = [
            "recent transactions",
            "show me latest transactions",
            "latest activity",
            "what did i spend on recently",
            "recent purchases list",
            "show my last few transactions",
        ]
        for prompt in prompts:
            with self.subTest(prompt=prompt):
                response = self._ask(prompt)
                self.assertEqual(response["intent"], "recent_transactions")
                self.assertEqual(response["answer_source"], "deterministic")
                self.assertEqual(response.get("period_resolved"), "recent")
                self.assertIn("recent_transactions", response.get("facts_used", []))

    def test_watchlist_paraphrases_do_not_hard_fail(self):
        # Reserved for future additions when we add broader phrasing not yet strict.
        self.assertTrue(True)

    def test_amount_time_aliases_this_month_and_last_year(self):
        month_prompts = [
            "how much did i spend this month",
            "how much did i spend current month",
            "how much did i spend this mo",
        ]
        for prompt in month_prompts:
            with self.subTest(prompt=prompt):
                response = self._ask(prompt)
                self.assertEqual(response["intent"], "amount_lookup")
                self.assertEqual(response["answer_source"], "deterministic")

        year_prompts = [
            "how much did i spend last year",
            "how much did i spend previous year",
            "how much did i spend prior year",
            "how much did i spend this yr",
        ]
        for prompt in year_prompts:
            with self.subTest(prompt=prompt):
                response = self._ask(prompt)
                self.assertEqual(response["intent"], "amount_lookup")
                self.assertEqual(response["answer_source"], "deterministic")

    def test_typo_tolerance_core_prompts(self):
        cases = [
            ("why did my speding increase lst month", "explain", "deterministic"),
            ("top categry lst month", "top_category_lookup", "deterministic"),
            ("show latest transections", "recent_transactions", "deterministic"),
            ("what caused my spendng to go up last mo", "explain", "deterministic"),
        ]
        for prompt, expected_intent, expected_source in cases:
            with self.subTest(prompt=prompt):
                response = self._ask(prompt)
                self.assertEqual(response["intent"], expected_intent)
                self.assertEqual(response["answer_source"], expected_source)

    def test_colloquial_abbreviation_tolerance(self):
        cases = [
            ("pls show latest transactions", "recent_transactions", "deterministic"),
            ("wanna know why ur spending increased last month", "explain", "deterministic"),
            (
                "what category did u spend most on last month",
                "top_category_lookup",
                "deterministic",
            ),
            ("gonna compare 2026-03 vs 2026-04", "compare_periods", "deterministic"),
        ]
        for prompt, expected_intent, expected_source in cases:
            with self.subTest(prompt=prompt):
                response = self._ask(prompt)
                self.assertEqual(response["intent"], expected_intent)
                self.assertEqual(response["answer_source"], expected_source)

    def test_noise_tolerance_punctuation_and_emoji(self):
        cases = [
            ("why did my spending increase last month???", "explain", "deterministic"),
            ("top category last month!!!", "top_category_lookup", "deterministic"),
            ("show latest transactions 📈", "recent_transactions", "deterministic"),
            ("compare 2026-03 vs 2026-04... pls", "compare_periods", "deterministic"),
        ]
        for prompt, expected_intent, expected_source in cases:
            with self.subTest(prompt=prompt):
                response = self._ask(prompt)
                self.assertEqual(response["intent"], expected_intent)
                self.assertEqual(response["answer_source"], expected_source)
