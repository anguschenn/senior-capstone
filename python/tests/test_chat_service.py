import unittest

from ai.chat_service import ChatService


class TestChatServiceContract(unittest.TestCase):
    def _service_with_reply(self, llm_reply):
        def generate_reply(_prompt, generation_config=None):
            _ = generation_config
            return llm_reply

        def get_detailed_snapshot(_user_id):
            return "snapshot"

        return ChatService(generate_reply=generate_reply, get_detailed_snapshot=get_detailed_snapshot)

    def test_chat_returns_structured_contract_on_json_reply(self):
        service = self._service_with_reply(
            '{"reply":"You are trending within budget.","insights":["30d expenses are stable"],"actions":["Keep weekly check-ins"]}'
        )

        payload = {
            "prompt": "How am I doing this month?",
            "history": [],
            "spending_summary": {
                "totals": {
                    "income_30d": 4000,
                    "expenses_30d": 2500,
                    "tx_count_30d": 22,
                    "expense_tx_count_30d": 18,
                }
            },
        }

        response = service.handle_chat(payload, user_id="demo-user")

        self.assertIn("reply", response)
        self.assertIn("insights", response)
        self.assertIn("actions", response)
        self.assertIn("confidence", response)
        self.assertIn("citations", response)
        self.assertEqual(response["reply"], "You are trending within budget.")
        self.assertEqual(response["insights"], ["30d expenses are stable"])
        self.assertIn("Keep weekly check-ins", response["actions"])
        self.assertGreaterEqual(response["confidence"], 0.0)
        self.assertLessEqual(response["confidence"], 1.0)

    def test_chat_adds_quantified_action_when_missing(self):
        service = self._service_with_reply(
            '{"reply":"You are trending within budget.","insights":["30d expenses are stable"],"actions":["Review spending weekly"]}'
        )

        payload = {
            "prompt": "How can I improve?",
            "history": [],
            "spending_summary": {
                "totals": {
                    "income_30d": 4000,
                    "expenses_30d": 2500,
                    "tx_count_30d": 22,
                    "expense_tx_count_30d": 18,
                },
                "top_expense_categories": [
                    {"category": "Transfer Out Account", "amount": 150},
                    {"category": "Food And Drink Fast Food", "amount": 120},
                ],
            },
        }

        response = service.handle_chat(payload, user_id="demo-user")
        self.assertTrue(any(("$" in action or any(ch.isdigit() for ch in action)) for action in response["actions"]))
        self.assertTrue(any("Food And Drink Fast Food" in action for action in response["actions"]))

    def test_chat_fallback_contract_on_exception(self):
        def generate_reply(_prompt, generation_config=None):
            _ = generation_config
            raise RuntimeError("llm down")

        def get_detailed_snapshot(_user_id):
            return "snapshot"

        service = ChatService(generate_reply=generate_reply, get_detailed_snapshot=get_detailed_snapshot)

        payload = {
            "prompt": "Give me advice",
            "history": [],
            "spending_summary": None,
        }

        response = service.handle_chat(payload, user_id="demo-user")

        self.assertEqual(response["context_source"], "rule_fallback")
        self.assertEqual(response["citations"], ["rule_fallback"])
        self.assertIsInstance(response["insights"], list)
        self.assertIsInstance(response["actions"], list)
        self.assertGreater(len(response["insights"]), 0)
        self.assertGreater(len(response["actions"]), 0)
        self.assertAlmostEqual(response["confidence"], 0.35, places=2)

    def test_chat_does_not_use_server_snapshot_when_summary_missing(self):
        def generate_reply(_prompt, generation_config=None):
            _ = generation_config
            return '{"reply":"Not enough app data yet.","insights":["Summary is empty"],"actions":["Sync and retry"]}'

        def get_detailed_snapshot(_user_id):
            raise AssertionError("Server snapshot should not be called")

        service = ChatService(generate_reply=generate_reply, get_detailed_snapshot=get_detailed_snapshot)

        payload = {
            "prompt": "What should I do next?",
            "history": [],
            "spending_summary": None,
        }

        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["context_source"], "frontend_summary_empty")
        self.assertFalse(response["used_summary"])


if __name__ == "__main__":
    unittest.main()
