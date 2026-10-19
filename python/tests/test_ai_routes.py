import unittest
from unittest import mock

from route_helpers import VALID_TOKEN, app_client, headers

import app_factory


class SuggestCategoryTests(unittest.TestCase):
    def test_calls_provider_with_its_real_signature(self):
        provider = mock.create_autospec(
            app_factory.generate_llm_reply, return_value="  Coffee Shops \n"
        )
        with app_client(generate_reply=provider) as client:
            response = client.post(
                "/api/ai/suggest_category",
                json={"merchant_name": "Starbucks", "transaction_name": "STARBUCKS #123"},
                headers=headers(VALID_TOKEN),
            )

        self.assertEqual(response.status_code, 200)
        body = response.get_json()
        self.assertEqual(body["suggested_category"], "Coffee Shops")
        self.assertEqual(body["context_source"], "ai_suggestion")
        provider.assert_called_once()
        prompt = provider.call_args.args[0]
        self.assertIn("Merchant: Starbucks", prompt)
        self.assertIn("Description: STARBUCKS #123", prompt)


class ChatQuestionLogTests(unittest.TestCase):
    def test_chat_records_the_question_and_response(self):
        recorded = []
        with app_client() as client:
            client.application.config["question_log"] = lambda p, r: recorded.append((p, r))
            response = client.post(
                "/api/ai/chat",
                json={"prompt": "hello", "history": [], "spending_summary": {}},
                headers=headers(VALID_TOKEN),
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(recorded), 1)
        self.assertEqual(recorded[0][0], "hello")
        self.assertEqual(recorded[0][1]["reply"], response.get_json()["reply"])


if __name__ == "__main__":
    unittest.main()
