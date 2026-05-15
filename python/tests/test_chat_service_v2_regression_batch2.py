import os
import unittest

from ai.chat_service import ChatService


class TestChatServiceV2RegressionBatch2(unittest.TestCase):
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
            "top_expense_categories": [{"category": "Subscriptions", "amount": 131}],
            "recent_transactions": [
                {"date": "2026-05-08", "name": "Netflix", "amount": -15.99},
                {"date": "2026-05-07", "name": "Uber", "amount": -12.5},
                {"date": "2026-05-06", "name": "Spotify", "amount": -10.99},
            ],
            "totals": {"tx_count_30d": 22, "income_30d": 3898, "expenses_30d": 3842},
        }

    def _ask(self, prompt):
        svc = self._service()
        return svc.handle_chat(
            {"prompt": prompt, "history": [], "spending_summary": self._summary()},
            user_id="demo-user",
        )

    def test_compare_prompt_family_routes_to_deterministic_compare(self):
        prompts = [
            "compare 2026-03 vs 2026-04",
            "compare 2026-03 and 2026-04",
            "difference between 2026-03 and 2026-04 spending",
            "month over month from 2026-03 to 2026-04",
            "MoM 2026-03 vs 2026-04",
            "between 2026-03 and 2026-04 spending difference",
        ]
        for prompt in prompts:
            with self.subTest(prompt=prompt):
                response = self._ask(prompt)
                self.assertEqual(response["answer_source"], "deterministic")
                self.assertEqual(response["intent"], "compare_periods")
                self.assertIn("2026-03", response.get("period_resolved", ""))
                self.assertIn("2026-04", response.get("period_resolved", ""))
                self.assertIn(
                    "month_index.expenses/year_index.expenses",
                    response.get("facts_used", []),
                )

    def test_recent_plus_advice_mixed_prompt_prefers_recent_deterministic(self):
        prompts = [
            "recent transactions and suggest optimizations",
            "show latest transactions and tell me what to improve",
            "latest activity with advice",
        ]
        for prompt in prompts:
            with self.subTest(prompt=prompt):
                response = self._ask(prompt)
                self.assertEqual(response["answer_source"], "deterministic")
                self.assertEqual(response["intent"], "recent_transactions")
                self.assertEqual(response.get("period_resolved"), "recent")
                self.assertIn("recent_transactions", response.get("facts_used", []))
                self.assertIn("Most recent transactions", response.get("reply", ""))

    def test_top_category_plus_advice_mixed_prompt_prefers_top_category_deterministic(self):
        prompts = [
            "top category last month and how can I reduce it",
            "what category did I spend most on last month and what should I do",
            "top spend category last month with recommendations",
        ]
        for prompt in prompts:
            with self.subTest(prompt=prompt):
                response = self._ask(prompt)
                self.assertEqual(response["answer_source"], "deterministic")
                self.assertEqual(response["intent"], "top_category_lookup")
                self.assertEqual(response.get("period_resolved"), "2026-04")
                self.assertIn("month_index.top_category", response.get("facts_used", []))
                self.assertIn("top category", response.get("reply", "").lower())
