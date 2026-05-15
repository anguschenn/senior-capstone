import os
import unittest

from ai.chat_service import ChatService


class TestChatServiceV2Regression(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Ensure v2 path is enabled for this regression suite.
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
                    "top_category": {"name": "Subscriptions", "amount": 131},
                },
                "2026-03": {
                    "income": 1800.0,
                    "expenses": 1750.0,
                    "top_category": {"name": "Food", "amount": 120},
                },
            },
            "top_expense_categories": [{"category": "Subscriptions", "amount": 131}],
            "recent_transactions": [
                {"date": "2026-05-08", "name": "Netflix", "amount": -15.99},
                {"date": "2026-05-07", "name": "Uber", "amount": -12.5},
            ],
            "totals": {"tx_count_30d": 22, "income_30d": 3898, "expenses_30d": 3842},
        }

    def _ask(self, prompt):
        svc = self._service()
        return svc.handle_chat(
            {"prompt": prompt, "history": [], "spending_summary": self._summary()},
            user_id="demo-user",
        )

    def test_spending_change_paraphrases_are_deterministic(self):
        prompts = [
            "why did my spending increase last month",
            "what caused my spending to go up last month",
            "help me understand why spending grew last month",
        ]
        for prompt in prompts:
            with self.subTest(prompt=prompt):
                response = self._ask(prompt)
                self.assertEqual(response["answer_source"], "deterministic")
                self.assertEqual(response["intent"], "explain")
                self.assertEqual(response.get("period_resolved"), "2026-04 vs 2026-03")
                self.assertIn("month_index.expenses", response.get("facts_used", []))

    def test_compare_periods_is_deterministic(self):
        response = self._ask("compare 2026-03 vs 2026-04")
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertEqual(response["intent"], "compare_periods")
        self.assertEqual(response.get("period_resolved"), "2026-03 vs 2026-04")
        self.assertIn("month_index.expenses/year_index.expenses", response.get("facts_used", []))

    def test_top_category_last_month_is_deterministic(self):
        response = self._ask("top category last month")
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertEqual(response["intent"], "top_category_lookup")
        self.assertEqual(response.get("period_resolved"), "2026-04")
        self.assertIn("month_index.top_category", response.get("facts_used", []))

    def test_recent_transactions_is_deterministic(self):
        response = self._ask("recent transactions")
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertEqual(response["intent"], "recent_transactions")
        self.assertEqual(response.get("period_resolved"), "recent")
        self.assertIn("recent_transactions", response.get("facts_used", []))
