import unittest
from unittest import mock

from route_helpers import VALID_TOKEN, app_client, headers

import app_factory
from ai import providers
from routes import ai_routes


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


class ChatServerSummaryTests(unittest.TestCase):
    """With a `context` block the chat answers from the server-built summary."""

    SERVER_SUMMARY = {
        "version": 3,
        "scope": "all_accounts",
        "month_index": {
            "2026-10": {"income": 0, "expenses": 123.45, "tx_count": 3, "expense_tx_count": 3}
        },
        "time_anchor": {"selected_month": "2026-10", "selected_year": 2026, "tz": ""},
    }
    CONTEXT = {"account_ids": [], "selected_month": "2026-10", "today": "2026-10-10"}

    def _post(self, body, summary_for):
        with (
            app_client() as client,
            mock.patch.object(ai_routes.server_summary, "summary_for", summary_for),
        ):
            return client.post("/api/ai/chat", json=body, headers=headers(VALID_TOKEN))

    def test_server_summary_replaces_the_app_summary(self):
        seen = []

        def summary_for(user_id, context):
            seen.append((user_id, context["month"]))
            return self.SERVER_SUMMARY

        response = self._post(
            {"prompt": "How much did I spend this month?", "context": self.CONTEXT},
            summary_for,
        )
        body = response.get_json()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(seen, [("user-123", "2026-10")])
        self.assertEqual(body["summary_source"], "server")
        self.assertIn("123", body["reply"])

    def test_falls_back_to_the_app_summary_when_the_server_fails(self):
        def broken(user_id, context):
            raise RuntimeError("database down")

        response = self._post(
            {"prompt": "hello", "context": self.CONTEXT, "spending_summary": {}}, broken
        )
        self.assertEqual(response.get_json()["summary_source"], "app")

    def test_asks_for_the_app_summary_when_it_has_none(self):
        def broken(user_id, context):
            raise RuntimeError("database down")

        response = self._post({"prompt": "hello", "context": self.CONTEXT}, broken)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json(), {"retry_with_summary": True})

    def test_old_clients_without_context_are_unchanged(self):
        def never(user_id, context):
            raise AssertionError("must not build a server summary")

        response = self._post({"prompt": "hello", "spending_summary": {}}, never)
        self.assertEqual(response.get_json()["summary_source"], "app")

    def test_disabled_flag_uses_the_app_summary(self):
        def never(user_id, context):
            raise AssertionError("must not build a server summary")

        with mock.patch.object(ai_routes, "CHAT_SERVER_SUMMARY_ENABLED", False):
            response = self._post({"prompt": "hello", "context": self.CONTEXT}, never)
        self.assertEqual(response.get_json(), {"retry_with_summary": True})


class RewriteCacheTests(unittest.TestCase):
    def test_a_cached_wording_skips_the_model(self):
        from ai.chat_service import ChatService

        calls = []

        class Cache:
            def __init__(self):
                self.stored = {}

            def get(self, message):
                return self.stored.get(message)

            def put(self, message, rewritten):
                self.stored[message] = rewritten

        def generate_reply(prompt, generation_config=None):
            calls.append(prompt)
            return "How much did I spend on Food this month?"

        service = ChatService(generate_reply, lambda _uid: "", rewrite_cache=Cache())
        first = service._rewrite_question("how cooked am i on food")
        second = service._rewrite_question("how cooked am i on food")
        self.assertEqual(first, second)
        self.assertEqual(len(calls), 1)

    def test_masked_wordings_are_never_cached(self):
        from ai.rewrite_cache import question_key

        self.assertEqual(question_key("How   cooked am I on FOOD"), "how cooked am i on food")
        self.assertEqual(question_key("can I afford a $400 phone"), "")
        self.assertEqual(question_key("email me at sam@example.com"), "")

    def test_cache_uses_the_table_and_swallows_errors(self):
        from fake_supabase import FakeSupabase

        from ai.rewrite_cache import SupabaseRewriteCache

        db = FakeSupabase()
        cache = SupabaseRewriteCache(client=db)
        cache.put("how cooked am I on food", "How much did I spend on Food this month?")
        fresh = SupabaseRewriteCache(client=db)  # empty memory: must read the table
        self.assertEqual(
            fresh.get("How cooked am I on food"), "How much did I spend on Food this month?"
        )
        self.assertEqual(db.tables["chat_rewrite_cache"][0]["hits"], 1)

        broken = mock.MagicMock()
        broken.table.side_effect = RuntimeError("no table")
        self.assertIsNone(SupabaseRewriteCache(client=broken).get("how cooked am i"))
        SupabaseRewriteCache(client=broken).put("how cooked am i", "x y z")


class QuestionLogTableTests(unittest.TestCase):
    def test_store_question_writes_the_masked_row_to_the_table(self):
        from fake_supabase import FakeSupabase

        from ai import question_log

        db = FakeSupabase()
        with mock.patch("supabase_repo.supabase", db):
            question_log._insert_row("Can I afford a $400 phone?", {"reply": "Likely yes."})
        (row,) = db.tables["chat_question_log"]
        self.assertEqual(row["question"], "Can I afford a [amount] phone?")
        self.assertEqual(row["outcome"], "answered")


class ModelSwitchTests(unittest.TestCase):
    def _ask(self, switch_enabled, model_source):
        seen = []

        def provider(prompt, generation_config=None):
            seen.append(providers.current_llm_info()["provider"])
            return "Cook at home more often."

        with app_client(generate_reply=provider) as client:
            client.application.config["model_switch_enabled"] = switch_enabled
            response = client.post(
                "/api/ai/chat",
                json={
                    "prompt": "How can I spend less on food?",
                    "history": [],
                    "spending_summary": {},
                    "model_source": model_source,
                },
                headers=headers(VALID_TOKEN),
            )
        return response.get_json(), seen

    def test_switch_picks_the_provider_per_request(self):
        for source, provider in (("local", "ollama"), ("online", "openrouter")):
            with self.subTest(source=source):
                body, seen = self._ask(True, source)
                self.assertTrue(seen)
                self.assertEqual(set(seen), {provider})
                self.assertEqual(body["model_used"]["provider"], provider)

    def test_switch_is_ignored_unless_enabled(self):
        body, _ = self._ask(False, "online")
        self.assertNotIn("model_used", body)


if __name__ == "__main__":
    unittest.main()
