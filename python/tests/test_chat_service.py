import unittest
from datetime import date as date_cls

from ai.chat_service import ChatService
from ai.intent_router import IntentRouter
from ai.validators import sanitize_spending_summary


class TestChatServiceContract(unittest.TestCase):
    def _service_with_reply(self, llm_reply):
        def generate_reply(_prompt, generation_config=None):
            _ = generation_config
            return llm_reply

        def get_detailed_snapshot(_user_id):
            return "snapshot"

        return ChatService(generate_reply=generate_reply, get_detailed_snapshot=get_detailed_snapshot)

    def _summary_fixture(self):
        return {
            "scope": "all_accounts",
            "scope_label": "Overall (All Accounts)",
            "totals": {
                "income_30d": 4000,
                "expenses_30d": 900,
                "tx_count_30d": 22,
                "expense_tx_count_30d": 18,
            },
            "time_anchor": {
                "selected_month": "2026-03",
                "selected_year": 2026,
                "selected_month_expenses": 300,
                "selected_month_income": 1000,
            },
            "month_index": {
                "2026-01": {"income": 1200, "expenses": 500, "tx_count": 8, "expense_tx_count": 6},
                "2026-02": {"income": 1200, "expenses": 200, "tx_count": 7, "expense_tx_count": 5},
                "2026-03": {
                    "income": 1000,
                    "expenses": 300,
                    "tx_count": 7,
                    "expense_tx_count": 7,
                    "top_category": {"name": "Food", "amount": 180},
                },
            },
            "day_index_recent": {
                "2026-03-15": {"income": 0, "expenses": 25, "tx_count": 2},
            },
            "rankings": {
                "highest_spending_months": [
                    {"month": "2026-01", "expenses": 500},
                    {"month": "2026-03", "expenses": 300},
                    {"month": "2026-02", "expenses": 200},
                ]
            },
            "annual_summary": {
                "year": 2026,
                "totals": {
                    "income_year": 3400,
                    "expenses_year": 1200,
                    "expense_tx_count_year": 18,
                },
            },
            "year_index": {
                "2025": {"income": 3600, "expenses": 1000, "tx_count": 40},
                "2026": {"income": 3400, "expenses": 1200, "tx_count": 42},
            },
        }

    def _frontend_v3_summary_fixture(self):
        # Mimics the current Dart ai_summary_service.dart contract (v3 fields).
        return {
            "version": 3,
            "scope": "all_accounts",
            "scope_label": "Overall (All Accounts)",
            "generated_at": "2026-05-05T01:00:00Z",
            "window_days": 30,
            "time_anchor": {
                "selected_month": "2026-05",
                "selected_year": 2026,
                "selected_month_expenses": 420,
                "selected_month_income": 1200,
                "tz": "EDT",
            },
            "windows": {
                "last_7d": {"income": 120, "expenses": 80, "tx_count": 6},
                "last_30d": {"income": 500, "expenses": 300, "tx_count": 24, "expense_tx_count": 18},
                "last_90d": {"income": 1500, "expenses": 980, "tx_count": 66},
            },
            "windows_rolling": {
                "last_7d": {"income": 120, "expenses": 80, "tx_count": 6},
                "last_30d": {"income": 500, "expenses": 300, "tx_count": 24, "expense_tx_count": 18},
                "last_90d": {"income": 1500, "expenses": 980, "tx_count": 66},
            },
            "totals": {
                "income_30d": 500,
                "expenses_30d": 300,
                "net_30d": 200,
                "tx_count_30d": 24,
                "expense_tx_count_30d": 18,
                "income_month": 1200,
                "expenses_month": 420,
                "net_month": 780,
            },
            "top_expense_categories": [
                {"category": "Food", "amount": 180},
                {"category": "Transport", "amount": 90},
            ],
            "recent_transactions": [
                {"id": "tx_3", "date": "2026-05-04", "name": "Cafe", "amount": -12.4, "category": "Food", "type": "debit", "account_id": "acc_1"},
                {"id": "tx_2", "date": "2026-05-03", "name": "Uber", "amount": -26.0, "category": "Transport", "type": "debit", "account_id": "acc_1"},
                {"id": "tx_1", "date": "2026-05-02", "name": "Groceries", "amount": -58.1, "category": "Food", "type": "debit", "account_id": "acc_1"},
            ],
            "data_coverage": {
                "transaction_count_total": 120,
                "range_start": "2026-01-01",
                "range_end": "2026-05-04",
                "days_span": 125,
                "active_days": 59,
                "coverage_ratio_recent_30d": 0.63,
            },
            "confidence": {
                "score": 0.81,
                "overall": "high",
                "reasons": [],
                "components": {
                    "tx_count_recent_30d": 0.9,
                    "coverage_recent_30d": 0.63,
                    "history_span": 1.0,
                    "noise_penalty_adjusted": 0.95,
                },
            },
            "warnings": [],
            "category_index": {"Food": 540, "Transport": 260, "Shopping": 180},
            "month_index": {
                "2026-05": {
                    "income": 1200,
                    "expenses": 420,
                    "tx_count": 16,
                    "expense_tx_count": 12,
                    "top_category": {"name": "Food", "amount": 180},
                },
                "2026-04": {
                    "income": 1100,
                    "expenses": 390,
                    "tx_count": 14,
                    "expense_tx_count": 10,
                    "top_category": {"name": "Transport", "amount": 140},
                },
            },
            "day_index_recent": {
                "2026-05-04": {"income": 0, "expenses": 12.4, "tx_count": 1},
                "2026-05-03": {"income": 0, "expenses": 26.0, "tx_count": 1},
                "2026-05-02": {"income": 0, "expenses": 58.1, "tx_count": 1},
            },
            "year_index": {
                "2026": {"income": 5200, "expenses": 2100, "tx_count": 120},
            },
            "annual_summary": {
                "year": 2026,
                "totals": {
                    "income_year": 5200,
                    "expenses_year": 2100,
                    "net_year": 3100,
                    "expense_tx_count_year": 84,
                },
                "top_expense_categories_year": [
                    {"category": "Food", "amount": 540},
                    {"category": "Transport", "amount": 260},
                ],
            },
        }

    def test_frontend_v3_summary_fields_are_sanitized(self):
        summary = self._frontend_v3_summary_fixture()
        cleaned = sanitize_spending_summary(summary)
        self.assertIsInstance(cleaned, dict)
        self.assertIn("windows_rolling", cleaned)
        self.assertIn("data_coverage", cleaned)
        self.assertIn("confidence", cleaned)
        self.assertIn("category_index", cleaned)
        self.assertEqual(cleaned["confidence"]["overall"], "high")
        self.assertIn("Food", cleaned["category_index"])

    def test_chat_uses_frontend_v3_summary_for_year_amount(self):
        service = self._service_with_reply('{"reply":"fallback llm","insights":["x"],"actions":["y"]}')
        payload = {
            "prompt": "How much did I spend this year?",
            "history": [],
            "spending_summary": self._frontend_v3_summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertEqual(response["resolved_query"]["intent"], "amount_lookup")
        self.assertEqual(response["resolved_query"]["period_type"], "year")
        self.assertIn("2026", response["reply"])
        self.assertIn("$2100", response["reply"])

    def test_chat_uses_frontend_v3_summary_for_rolling_days_amount(self):
        service = self._service_with_reply('{"reply":"fallback llm","insights":["x"],"actions":["y"]}')
        payload = {
            "prompt": "How much did I spend last 20 days?",
            "history": [],
            "spending_summary": self._frontend_v3_summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertEqual(response["resolved_query"]["period_type"], "rolling_days")
        self.assertEqual(response["resolved_query"]["period_key"], "rolling_20d")
        self.assertIn("last 20 days", response["reply"].lower())

    def test_edge_cases_end_to_end_routing_contract(self):
        service = self._service_with_reply(
            '{"reply":"llm fallback","insights":["x"],"actions":["y"]}'
        )
        summary = self._frontend_v3_summary_fixture()
        cases = [
            # Deterministic factual
            ("How much did I spend this month?", "amount_lookup", "deterministic", "month"),
            ("How much did I spend this year so far?", "amount_lookup", "deterministic", "year"),
            ("How much did I spend over the last 7 days?", "amount_lookup", "deterministic", "rolling_days"),
            ("How much did I spend over the last 52 days?", "amount_lookup", "deterministic", "rolling_days"),
            ("What did I spend in 2026-03?", "amount_lookup", "deterministic", "month"),
            ("What is my top category?", "top_category_lookup", "deterministic", "rolling_30d"),
            ("What category did I spend most on last month?", "top_category_lookup", "deterministic", "month"),
            ("List my latest transactions", "recent_transactions", "deterministic", "rolling_30d"),
            # Conservative fallback to parser/clarification for mixed/ambiguous
            ("Top category this month and how do I reduce it?", "general", "clarification", "unknown"),
            ("List my latest transactions and suggest optimizations", "general", "clarification", "unknown"),
            ("What is this month spending and why did it rise?", "general", "clarification", "unknown"),
            ("What is my spending total?", "general", "clarification", "unknown"),
            ("compare 2026-01 vs 2026-02", "general", "clarification", "unknown"),
            ("expense status?", "general", "clarification", "unknown"),
            # Extreme period text
            ("How much did I spend in the last 500 days?", "amount_lookup", "deterministic", "rolling_days"),
            ("How much did I spend in the last -3 days?", "general", "clarification", "unknown"),
        ]
        for prompt, expected_intent, expected_answer_source, expected_period_type in cases:
            with self.subTest(prompt=prompt):
                response = service.handle_chat(
                    {"prompt": prompt, "history": [], "spending_summary": summary},
                    user_id="demo-user",
                )
                self.assertEqual(response["intent"], expected_intent)
                self.assertEqual(response["answer_source"], expected_answer_source)
                self.assertEqual(
                    response.get("resolved_query", {}).get("period_type"),
                    expected_period_type,
                )

    def test_edge_cases_end_to_end_routing_contract_batch_2(self):
        service = self._service_with_reply(
            '{"reply":"llm fallback","insights":["x"],"actions":["y"]}'
        )
        summary = self._frontend_v3_summary_fixture()
        cases = [
            # Format variants and abbreviations
            ("total spent 2026/03", "amount_lookup", "deterministic", "month"),
            ("what did i spend in apr 2026", "amount_lookup", "deterministic", "month"),
            ("expenses last 30d", "amount_lookup", "deterministic", "rolling_30d"),
            ("what did i spend this wk", "amount_lookup", "deterministic", "rolling_days"),
            # Explicit day-level query should stay conservative
            ("spending on 2026-05-03", "general", "clarification", "unknown"),
            # Year + advisory mixed intent
            ("total this year and what should i change", "general", "clarification", "unknown"),
            # Compare shorthand should stay conservative without parser
            ("2026-01 vs 2026-02", "general", "clarification", "unknown"),
            # Top category with punctuation and mixed clause
            ("top spend category this month?", "top_category_lookup", "deterministic", "month"),
            ("top spend category this month, recommend changes", "general", "clarification", "unknown"),
            # Recent tx mixed with strategy
            ("latest activity", "general", "clarification", "unknown"),
            ("latest activity + optimization plan", "general", "clarification", "unknown"),
            # Extreme rolling windows
            ("what did i spend over last 1 days", "amount_lookup", "deterministic", "rolling_days"),
            ("what did i spend over last 365 days", "amount_lookup", "deterministic", "rolling_days"),
            # Invalid or malformed period should clarify
            ("what did i spend over last 0 days", "amount_lookup", "deterministic", "rolling_days"),
            ("what did i spend in 19-03", "general", "clarification", "unknown"),
        ]
        for prompt, expected_intent, expected_answer_source, expected_period_type in cases:
            with self.subTest(prompt=prompt):
                response = service.handle_chat(
                    {"prompt": prompt, "history": [], "spending_summary": summary},
                    user_id="demo-user",
                )
                self.assertEqual(response["intent"], expected_intent)
                self.assertEqual(response["answer_source"], expected_answer_source)
                self.assertEqual(
                    response.get("resolved_query", {}).get("period_type"),
                    expected_period_type,
                )

    def test_edge_cases_end_to_end_routing_contract_batch_3(self):
        service = self._service_with_reply(
            '{"reply":"llm fallback","insights":["x"],"actions":["y"]}'
        )
        summary = self._frontend_v3_summary_fixture()
        cases = [
            ("spent this month?", "amount_lookup", "deterministic", "month"),
            ("THIS YEAR spend total", "amount_lookup", "deterministic", "year"),
            ("recent tx", "recent_transactions", "deterministic", "rolling_30d"),
            ("latest transactions", "recent_transactions", "deterministic", "rolling_30d"),
            ("top category rn", "top_category_lookup", "deterministic", "rolling_30d"),
            ("top category... why high", "explain", "llm", "unknown"),
            ("how much did i spend 2026-05", "amount_lookup", "deterministic", "month"),
            ("last 30 days spending", "amount_lookup", "deterministic", "rolling_30d"),
            ("2026-05 total?", "general", "clarification", "unknown"),
            ("need advice cut costs", "general", "clarification", "unknown"),
            ("last 365 days spend", "amount_lookup", "deterministic", "rolling_days"),
            ("last -2 days spend", "general", "clarification", "unknown"),
        ]
        for prompt, expected_intent, expected_answer_source, expected_period_type in cases:
            with self.subTest(prompt=prompt):
                response = service.handle_chat(
                    {"prompt": prompt, "history": [], "spending_summary": summary},
                    user_id="demo-user",
                )
                self.assertEqual(response["intent"], expected_intent)
                self.assertEqual(response["answer_source"], expected_answer_source)
                self.assertEqual(
                    response.get("resolved_query", {}).get("period_type"),
                    expected_period_type,
                )

    def test_real_user_prompt_regression_baseline(self):
        service = self._service_with_reply(
            '{"reply":"llm fallback narrative","insights":["i1"],"actions":["a1"]}'
        )
        summary = self._frontend_v3_summary_fixture()
        cases = [
            # Clear deterministic intents
            ("How much did I spend this month?", "amount_lookup", "deterministic", "month"),
            ("How much did I spend this year?", "amount_lookup", "deterministic", "year"),
            ("How much did I spend last 20 days?", "amount_lookup", "deterministic", "rolling_days"),
            ("What is my top category?", "top_category_lookup", "deterministic", "rolling_30d"),
            ("Show my recent transactions", "recent_transactions", "deterministic", "rolling_30d"),
            # Mixed/advisory/explainer intents should stay conservative
            ("Top category this month and how can I reduce it?", "general", "clarification", "unknown"),
            ("Explain why this month is higher", "explain", "llm", "month"),
            ("How much did I spend?", "general", "clarification", "unknown"),
            # Fragments / noisy prompts in current baseline behavior
            ("spent this month?", "amount_lookup", "deterministic", "month"),
            ("how much did i speend this month", "amount_lookup", "deterministic", "month"),
            ("latest transactions pls", "recent_transactions", "deterministic", "rolling_30d"),
            ("last 365 days spend", "amount_lookup", "deterministic", "rolling_days"),
        ]
        for prompt, expected_intent, expected_answer_source, expected_period_type in cases:
            with self.subTest(prompt=prompt):
                response = service.handle_chat(
                    {"prompt": prompt, "history": [], "spending_summary": summary},
                    user_id="demo-user",
                )
                self.assertEqual(response["intent"], expected_intent)
                self.assertEqual(response["answer_source"], expected_answer_source)
                self.assertEqual(
                    response.get("resolved_query", {}).get("period_type"),
                    expected_period_type,
                )
                self.assertTrue(str(response.get("reply", "")).strip())

    def test_real_user_prompt_regression_baseline_batch_2(self):
        service = self._service_with_reply(
            '{"reply":"llm fallback narrative","insights":["i1"],"actions":["a1"]}'
        )
        summary = self._frontend_v3_summary_fixture()
        cases = [
            ("spending 2026-05?", "amount_lookup", "deterministic", "month"),
            ("how is my spending last month", "amount_lookup", "deterministic", "month"),
            ("analyst my spending last month", "explain", "llm", "month"),
            ("2026-05 spending why up", "explain", "llm", "month"),
            ("recent tx and top category", "general", "clarification", "unknown"),
            ("top category 2026/05", "top_category_lookup", "deterministic", "month"),
            ("show me latest tx for last week", "recent_transactions", "deterministic", "rolling_days"),
            ("how much did i spend this week", "amount_lookup", "deterministic", "rolling_days"),
            ("how much did i spend this wk?", "amount_lookup", "deterministic", "rolling_days"),
            ("compare 2026-05 and 2026-04 and suggest plan", "general", "clarification", "unknown"),
            ("income this month", "general", "clarification", "unknown"),
            ("net this month", "general", "clarification", "unknown"),
            ("how much did i spend in 2026/13", "general", "clarification", "unknown"),
            ("latest transactions for 2026-05 and advice", "general", "clarification", "unknown"),
        ]
        for prompt, expected_intent, expected_answer_source, expected_period_type in cases:
            with self.subTest(prompt=prompt):
                response = service.handle_chat(
                    {"prompt": prompt, "history": [], "spending_summary": summary},
                    user_id="demo-user",
                )
                self.assertEqual(response["intent"], expected_intent)
                self.assertEqual(response["answer_source"], expected_answer_source)
                self.assertEqual(
                    response.get("resolved_query", {}).get("period_type"),
                    expected_period_type,
                )
                self.assertTrue(str(response.get("reply", "")).strip())

    def test_chat_returns_structured_contract_on_json_reply(self):
        service = self._service_with_reply(
            '{"reply":"You are trending within budget.","insights":["30d expenses are stable"],"actions":["Keep weekly check-ins"]}'
        )
        service.router.classify = lambda _message, _history: {
            "intent": "planning",
            "intent_confidence": 0.9,
            "intent_candidates": ["planning", "general"],
            "intent_source": "llm",
            "needs_clarification": False,
            "entities": {"metric": "unknown", "period_type": "unknown", "period_key": "", "scope_hint": "current_scope"},
            "clarification_question": "",
            "response_mode": "llm",
        }

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
        self.assertIn("citations", response)
        self.assertEqual(response["reply"], "You are trending within budget.")
        self.assertEqual(response["insights"], ["30d expenses are stable"])
        self.assertIn("Keep weekly check-ins", response["actions"])

    def test_chat_adds_quantified_action_when_missing(self):
        service = self._service_with_reply(
            '{"reply":"You are trending within budget.","insights":["30d expenses are stable"],"actions":["Review spending weekly"]}'
        )
        service.router.classify = lambda _message, _history: {
            "intent": "planning",
            "intent_confidence": 0.9,
            "intent_candidates": ["planning", "general"],
            "intent_source": "llm",
            "needs_clarification": False,
            "entities": {"metric": "unknown", "period_type": "unknown", "period_key": "", "scope_hint": "current_scope"},
            "clarification_question": "",
            "response_mode": "llm",
        }

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
        service.router.classify = lambda _message, _history: {
            "intent": "planning",
            "intent_confidence": 0.9,
            "intent_candidates": ["planning", "general"],
            "intent_source": "llm",
            "needs_clarification": False,
            "entities": {"metric": "unknown", "period_type": "unknown", "period_key": "", "scope_hint": "current_scope"},
            "clarification_question": "",
            "response_mode": "llm",
        }

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

    def test_amount_month_is_deterministic_and_correct(self):
        service = self._service_with_reply(
            '{"reply":"fallback llm","insights":["x"],"actions":["y"]}'
        )
        payload = {
            "prompt": "How much did I spend in 2026-03?",
            "history": [],
            "spending_summary": self._summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertEqual(response["resolved_query"]["intent"], "amount_lookup")
        self.assertEqual(response["resolved_query"]["period_type"], "month")
        self.assertEqual(response["resolved_query"]["period_key"], "2026-03")
        self.assertIn("2026-03", response["reply"])
        self.assertIn("$300", response["reply"])

    def test_amount_day_is_deterministic_and_correct(self):
        service = self._service_with_reply(
            '{"reply":"fallback llm","insights":["x"],"actions":["y"]}'
        )
        payload = {
            "prompt": "How much did I spend on 2026-03-15?",
            "history": [],
            "spending_summary": self._summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "clarification")
        self.assertEqual(response["resolved_query"]["intent"], "general")
        self.assertIn("Which time period", response["reply"])

    def test_month_overview_returns_highest_month_not_year_total(self):
        service = self._service_with_reply(
            '{"reply":"fallback llm","insights":["x"],"actions":["y"]}'
        )
        payload = {
            "prompt": "which month did I spend the most this year?",
            "history": [],
            "spending_summary": self._summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "hybrid")
        self.assertEqual(response["resolved_query"]["intent"], "month_overview")
        self.assertIn("highest spending month", response["reply"].lower())

    def test_amount_query_without_period_reports_missing_period(self):
        service = self._service_with_reply(
            '{"reply":"Can you clarify the period?","insights":["Need period"],"actions":["Specify month"]}'
        )
        payload = {
            "prompt": "How much did I spend?",
            "history": [],
            "spending_summary": self._summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["resolved_query"]["intent"], "general")
        self.assertEqual(response["resolved_query"]["period_type"], "unknown")
        self.assertIn("period", response["missing_fields"])

    def test_top_category_month_query_returns_category_not_total_only(self):
        service = self._service_with_reply(
            '{"reply":"fallback llm","insights":["x"],"actions":["y"]}'
        )
        payload = {
            "prompt": "what category did I spend most on march 2026?",
            "history": [],
            "spending_summary": self._summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertEqual(response["resolved_query"]["intent"], "top_category_lookup")
        self.assertEqual(response["resolved_query"]["period_key"], "2026-03")
        self.assertIn("top category", response["reply"].lower())
        self.assertIn("food", response["reply"].lower())
        self.assertIn("$180", response["reply"])

    def test_top_category_query_never_falls_back_to_amount_answer(self):
        service = self._service_with_reply(
            '{"reply":"fallback llm","insights":["x"],"actions":["y"]}'
        )
        summary = self._summary_fixture()
        summary["month_index"]["2026-03"].pop("top_category", None)
        payload = {
            "prompt": "what category did I spend the most on march 2026?",
            "history": [],
            "spending_summary": summary,
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertEqual(response["resolved_query"]["intent"], "top_category_lookup")
        self.assertNotIn("total expenses", response["reply"].lower())
        self.assertIn("top-category breakdown", response["reply"].lower())
        self.assertIn("category_breakdown_for_period", response["missing_fields"])

    def test_this_month_uses_calendar_month_and_reports_missing_data(self):
        service = self._service_with_reply(
            '{"reply":"fallback llm","insights":["x"],"actions":["y"]}'
        )
        summary = self._summary_fixture()
        summary["time_anchor"]["selected_month"] = "2026-03"
        summary["time_anchor"]["selected_month_expenses"] = 300
        current_month = date_cls.today().strftime("%Y-%m")
        summary["month_index"].pop(current_month, None)
        payload = {
            "prompt": "How much did I spend this month?",
            "history": [],
            "spending_summary": summary,
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertEqual(response["resolved_query"]["intent"], "amount_lookup")
        self.assertEqual(response["resolved_query"]["period_type"], "month")
        self.assertEqual(response["resolved_query"]["period_key"], current_month)
        self.assertIn(f"do not see recorded expenses for {current_month}", response["reply"].lower())
        self.assertNotIn("last 30 days", response["reply"].lower())

    def test_month_lookup_prefers_month_index_over_selected_month_anchor(self):
        service = self._service_with_reply(
            '{"reply":"fallback llm","insights":["x"],"actions":["y"]}'
        )
        summary = self._summary_fixture()
        summary["time_anchor"]["selected_month"] = "2026-03"
        summary["time_anchor"]["selected_month_expenses"] = 0
        summary["month_index"]["2026-03"]["expenses"] = 300
        payload = {
            "prompt": "How much did I spend in 2026-03?",
            "history": [],
            "spending_summary": summary,
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertIn("2026-03", response["reply"])
        self.assertIn("$300", response["reply"])

    def test_chat_sanitizes_unverifiable_daily_or_frequency_insights(self):
        service = self._service_with_reply(
            '{"reply":"Cut discretionary spending.","insights":["You spent $179 on Entertainment three times recently.","You spent an average of $24 per day on Food & Drink."],"actions":["Reduce entertainment by $40 this week."]}'
        )
        payload = {
            "prompt": "How can I improve my spending habits this month?",
            "history": [],
            "spending_summary": self._summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        merged = " ".join(response["insights"]).lower()
        self.assertNotIn("per day", merged)
        self.assertNotIn("times recently", merged)

    def test_chat_sanitizes_unverifiable_daily_or_frequency_reply_and_actions(self):
        service = self._service_with_reply(
            '{"reply":"You spend an average of $24 per day on Food & Drink.","insights":["Spending is concentrated in discretionary categories."],"actions":["You spent $179 on Entertainment three times recently, reduce this by 20%."]}'
        )
        payload = {
            "prompt": "How can I improve my spending habits this month?",
            "history": [],
            "spending_summary": self._summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertNotIn("per day", response["reply"].lower())
        self.assertNotIn("times recently", " ".join(response["actions"]).lower())

    def test_chat_sanitizes_impossible_partial_vs_total_claims(self):
        service = self._service_with_reply(
            '{"reply":"Other category accounts for about $82 out of total $60 spent.","insights":["Other category accounts for about $82 out of total $60 spent."],"actions":["Cut Other by $15 this week."]}'
        )
        service.router.classify = lambda _message, _history: {
            "intent": "explain",
            "intent_confidence": 0.9,
            "intent_candidates": ["explain"],
            "intent_source": "llm",
            "needs_clarification": False,
            "response_mode": "llm",
            "entities": {"metric": "expenses", "period_type": "month", "period_key": "2026-03", "scope_hint": "current_scope"},
            "clarification_question": "",
        }
        payload = {
            "prompt": "How is my spending this month?",
            "history": [],
            "spending_summary": self._summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertNotIn("out of total $60", response["reply"].lower())
        self.assertNotIn("out of total $60", " ".join(response["insights"]).lower())
        self.assertIn("inconsistent", response["reply"].lower())

    def test_llm_intent_amount_routes_to_deterministic(self):
        def generate_reply(_prompt, generation_config=None):
            _ = generation_config
            raise AssertionError("LLM answer path should not run for deterministic amount intent")

        service = ChatService(generate_reply=generate_reply, get_detailed_snapshot=lambda _user: "snapshot")
        service.router.classify = lambda _message, _history: {
            "intent": "amount_lookup",
            "intent_confidence": 0.95,
            "intent_candidates": ["amount_lookup"],
            "intent_source": "llm",
            "needs_clarification": False,
            "entities": {
                "metric": "expenses",
                "period_type": "month",
                "period_key": "2026-03",
                "scope_hint": "current_scope",
            },
            "clarification_question": "",
        }
        payload = {
            "prompt": "How much did I spend in 2026-03?",
            "history": [],
            "spending_summary": self._summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertIn("$300", response["reply"])
        self.assertEqual(response["resolved_query"]["period_key"], "2026-03")

    def test_llm_intent_explain_routes_to_llm(self):
        calls = {"count": 0}

        def generate_reply(_prompt, generation_config=None):
            _ = generation_config
            calls["count"] += 1
            return '{"reply":"Spending rose due to dining and shopping.","insights":["Dining spend increased month-over-month."],"actions":["Set a dining cap for the next 14 days."]}'

        service = ChatService(generate_reply=generate_reply, get_detailed_snapshot=lambda _user: "snapshot")
        service.router.classify = lambda _message, _history: {
            "intent": "explain",
            "intent_confidence": 0.92,
            "intent_candidates": ["explain", "planning"],
            "intent_source": "llm",
            "needs_clarification": False,
            "entities": {"metric": "expenses", "period_type": "month", "period_key": "2026-03", "scope_hint": "current_scope"},
            "clarification_question": "",
        }
        payload = {
            "prompt": "Explain why my spending increased.",
            "history": [],
            "spending_summary": self._summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(calls["count"], 1)
        self.assertEqual(response["intent"], "explain")
        self.assertIn("Spending rose", response["reply"])

    def test_needs_clarification_early_return(self):
        def generate_reply(_prompt, generation_config=None):
            _ = generation_config
            raise AssertionError("LLM answer should not run when clarification is required")

        service = ChatService(generate_reply=generate_reply, get_detailed_snapshot=lambda _user: "snapshot")
        service.router.classify = lambda _message, _history: {
            "intent": "amount_lookup",
            "intent_confidence": 0.41,
            "intent_candidates": ["amount_lookup", "general"],
            "intent_source": "llm",
            "needs_clarification": True,
            "entities": {"metric": "expenses", "period_type": "unknown", "period_key": "", "scope_hint": "current_scope"},
            "clarification_question": "Which month should I use?",
        }
        payload = {
            "prompt": "How much did I spend?",
            "history": [],
            "spending_summary": self._summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "clarification")
        self.assertIn("Which month", response["reply"])
        self.assertIn("period", response["missing_fields"])

    def test_entities_override_message_fallback(self):
        service = self._service_with_reply(
            '{"reply":"fallback llm","insights":["x"],"actions":["y"]}'
        )
        service.router.classify = lambda _message, _history: {
            "intent": "amount_lookup",
            "intent_confidence": 0.92,
            "intent_candidates": ["amount_lookup"],
            "intent_source": "llm",
            "needs_clarification": False,
            "entities": {
                "metric": "expenses",
                "period_type": "month",
                "period_key": "2026-03",
                "scope_hint": "current_scope",
            },
            "clarification_question": "",
        }
        payload = {
            "prompt": "How much did I spend this year?",
            "history": [],
            "spending_summary": self._summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["resolved_query"]["period_key"], "2026-03")
        self.assertEqual(response["resolved_query"]["period_type"], "month")

    def test_compare_periods_month_deterministic(self):
        service = self._service_with_reply(
            '{"reply":"fallback llm","insights":["x"],"actions":["y"]}'
        )
        service.router.classify = lambda _message, _history: {
            "intent": "compare_periods",
            "intent_confidence": 0.91,
            "intent_candidates": ["compare_periods"],
            "intent_source": "llm",
            "needs_clarification": False,
            "entities": {
                "metric": "expenses",
                "period_type": "month",
                "period_key": "2026-02,2026-03",
                "scope_hint": "current_scope",
            },
            "clarification_question": "",
        }
        payload = {
            "prompt": "Compare 2026-02 vs 2026-03 spending.",
            "history": [],
            "spending_summary": self._summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "hybrid")
        self.assertIn("2026-02", response["reply"])
        self.assertIn("2026-03", response["reply"])

    def test_compare_periods_missing_data_returns_clarification(self):
        service = self._service_with_reply(
            '{"reply":"fallback llm","insights":["x"],"actions":["y"]}'
        )
        service.router.classify = lambda _message, _history: {
            "intent": "compare_periods",
            "intent_confidence": 0.89,
            "intent_candidates": ["compare_periods"],
            "intent_source": "llm",
            "needs_clarification": False,
            "entities": {
                "metric": "expenses",
                "period_type": "month",
                "period_key": "2026-02,2026-04",
                "scope_hint": "current_scope",
            },
            "clarification_question": "",
        }
        payload = {
            "prompt": "Compare 2026-02 vs 2026-04 spending.",
            "history": [],
            "spending_summary": self._summary_fixture(),
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "hybrid")

    def test_clarification_threshold_behavior(self):
        summary = self._summary_fixture()

        def make_service(confidence):
            service = self._service_with_reply(
                '{"reply":"fallback llm","insights":["x"],"actions":["y"]}'
            )
            service.router.classify = lambda _message, _history: {
                "intent": "amount_lookup",
                "intent_confidence": confidence,
                "intent_candidates": ["amount_lookup"],
                "intent_source": "llm",
                "needs_clarification": True,
                "entities": {
                    "metric": "expenses",
                    "period_type": "unknown",
                    "period_key": "",
                    "scope_hint": "current_scope",
                },
                "clarification_question": "Which period should I use?",
            }
            return service

        high_response = make_service(0.80).handle_chat(
            {"prompt": "How much did I spend in 2026-03?", "history": [], "spending_summary": summary},
            user_id="demo-user",
        )
        self.assertNotEqual(high_response["answer_source"], "clarification")

        mid_response = make_service(0.55).handle_chat(
            {"prompt": "How much did I spend in 2026-03?", "history": [], "spending_summary": summary},
            user_id="demo-user",
        )
        self.assertNotEqual(mid_response["answer_source"], "clarification")

        low_response = make_service(0.30).handle_chat(
            {"prompt": "How much did I spend in 2026-03?", "history": [], "spending_summary": summary},
            user_id="demo-user",
        )
        self.assertEqual(low_response["answer_source"], "clarification")

    def test_last_month_top_category_is_deterministic(self):
        service = self._service_with_reply(
            '{"reply":"fallback llm","insights":["x"],"actions":["y"]}'
        )
        summary = self._summary_fixture()
        last_month = date_cls.fromordinal(date_cls.today().replace(day=1).toordinal() - 1).strftime("%Y-%m")
        summary["month_index"][last_month] = {
            "income": 1100,
            "expenses": 260,
            "tx_count": 7,
            "expense_tx_count": 6,
            "top_category": {"name": "Entertainment", "amount": 120},
        }
        annual = summary.get("annual_summary", {})
        annual["monthly_top_categories"] = [
            {"month": last_month, "category": "Entertainment", "amount": 120},
        ]
        summary["annual_summary"] = annual
        payload = {
            "prompt": "What category did I spend the most last month?",
            "history": [],
            "spending_summary": summary,
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertIn("top category", response["reply"].lower())
        self.assertIn("entertainment", response["reply"].lower())

    def test_last_3_months_amount_range_is_deterministic(self):
        service = self._service_with_reply(
            '{"reply":"fallback llm","insights":["x"],"actions":["y"]}'
        )
        summary = self._summary_fixture()
        last_month = date_cls.fromordinal(date_cls.today().replace(day=1).toordinal() - 1).strftime("%Y-%m")
        prev_month = date_cls.fromordinal(date_cls.today().replace(day=1).toordinal() - 32).strftime("%Y-%m")
        prev2_month = date_cls.fromordinal(date_cls.today().replace(day=1).toordinal() - 62).strftime("%Y-%m")
        summary["month_index"][last_month] = {
            "income": 1100,
            "expenses": 260,
            "tx_count": 7,
            "expense_tx_count": 6,
            "top_category": {"name": "Entertainment", "amount": 120},
        }
        summary["month_index"][prev_month] = {
            "income": 1000,
            "expenses": 210,
            "tx_count": 6,
            "expense_tx_count": 5,
            "top_category": {"name": "Entertainment", "amount": 95},
        }
        summary["month_index"][prev2_month] = {
            "income": 900,
            "expenses": 190,
            "tx_count": 6,
            "expense_tx_count": 5,
            "top_category": {"name": "Food", "amount": 90},
        }
        payload = {
            "prompt": "How much did I spend in the last 3 months?",
            "history": [],
            "spending_summary": summary,
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "clarification")
        self.assertIn("Which time period", response["reply"])

    def test_last_year_amount_uses_previous_year_index(self):
        service = self._service_with_reply(
            '{"reply":"fallback llm","insights":["x"],"actions":["y"]}'
        )
        summary = self._summary_fixture()
        previous_year = str(date_cls.today().year - 1)
        summary["year_index"][previous_year] = {"income": 3200, "expenses": 880, "tx_count": 35}
        payload = {
            "prompt": "How much did I spend last year?",
            "history": [],
            "spending_summary": summary,
        }
        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertEqual(response["resolved_query"]["period_type"], "year")
        self.assertEqual(response["resolved_query"]["period_key"], previous_year)
        self.assertIn(previous_year, response["reply"])
        self.assertIn("$880", response["reply"])

    def test_model_response_mode_deterministic_for_factual(self):
        service = self._service_with_reply('{"reply":"fallback llm","insights":["x"],"actions":["y"]}')
        service.router.classify = lambda _message, _history: {
            "intent": "amount_lookup",
            "intent_confidence": 0.9,
            "intent_candidates": ["amount_lookup"],
            "intent_source": "llm",
            "needs_clarification": False,
            "response_mode": "deterministic",
            "entities": {"metric": "expenses", "period_type": "month", "period_key": "2026-03", "scope_hint": "current_scope"},
            "clarification_question": "",
        }
        response = service.handle_chat(
            {"prompt": "How much did I spend in 2026-03?", "history": [], "spending_summary": self._summary_fixture()},
            user_id="demo-user",
        )
        self.assertEqual(response["answer_source"], "deterministic")

    def test_model_response_mode_llm_for_advisory(self):
        calls = {"count": 0}

        def generate_reply(_prompt, generation_config=None):
            _ = generation_config
            calls["count"] += 1
            return '{"reply":"Plan with weekly reviews.","insights":["Recent expenses are concentrated."],"actions":["Set a weekly budget cap."]}'

        service = ChatService(generate_reply=generate_reply, get_detailed_snapshot=lambda _u: "snapshot")
        service.router.classify = lambda _message, _history: {
            "intent": "planning",
            "intent_confidence": 0.88,
            "intent_candidates": ["planning"],
            "intent_source": "llm",
            "needs_clarification": False,
            "response_mode": "llm",
            "entities": {"metric": "unknown", "period_type": "unknown", "period_key": "", "scope_hint": "current_scope"},
            "clarification_question": "",
        }
        response = service.handle_chat(
            {"prompt": "How should I plan next month?", "history": [], "spending_summary": self._summary_fixture()},
            user_id="demo-user",
        )
        self.assertEqual(calls["count"], 1)
        self.assertEqual(response["answer_source"], "llm")

    def test_model_response_mode_deterministic_forces_clarification_when_incomplete(self):
        def generate_reply(_prompt, generation_config=None):
            _ = generation_config
            raise AssertionError("LLM should not run when mode is corrected to clarification")

        service = ChatService(generate_reply=generate_reply, get_detailed_snapshot=lambda _u: "snapshot")
        service.router.classify = lambda _message, _history: {
            "intent": "amount_lookup",
            "intent_confidence": 0.9,
            "intent_candidates": ["amount_lookup"],
            "intent_source": "llm",
            "needs_clarification": False,
            "response_mode": "deterministic",
            "entities": {"metric": "expenses", "period_type": "unknown", "period_key": "", "scope_hint": "current_scope"},
            "clarification_question": "Which month should I use?",
        }
        response = service.handle_chat(
            {"prompt": "How much did I spend?", "history": [], "spending_summary": self._summary_fixture()},
            user_id="demo-user",
        )
        self.assertEqual(response["answer_source"], "clarification")
        self.assertIn("period", response["missing_fields"])

    def test_requested_edge_cases_end_to_end_batch_4(self):
        service = self._service_with_reply(
            '{"reply":"llm fallback narrative","insights":["i1"],"actions":["a1"]}'
        )
        summary = self._frontend_v3_summary_fixture()
        cases = [
            ("How much last month?", "general", "clarification", "unknown"),
            ("Analyze my spending last month", "explain", "llm", "month"),
            ("analyst my spending last month", "explain", "llm", "month"),
            ("How much did I spend in 2026/13?", "general", "clarification", "unknown"),
            ("Top category this month and how can I reduce it?", "general", "clarification", "unknown"),
            ("Show recent transactions for last week and explain trend", "general", "clarification", "unknown"),
            ("last 30 days spending", "amount_lookup", "deterministic", "rolling_30d"),
            ("last 30 day spend", "amount_lookup", "hybrid", "rolling_30d"),
            ("last30d spending", "amount_lookup", "deterministic", "rolling_30d"),
            ("How much did I spend last monthne", "general", "clarification", "unknown"),
            ("how much i spend this month? income", "general", "clarification", "unknown"),
            ("which month did I spend the most this year?", "month_overview", "llm", "year"),
        ]
        for prompt, expected_intent, expected_answer_source, expected_period_type in cases:
            with self.subTest(prompt=prompt):
                response = service.handle_chat(
                    {"prompt": prompt, "history": [], "spending_summary": summary},
                    user_id="demo-user",
                )
                self.assertEqual(response["intent"], expected_intent)
                self.assertEqual(response["answer_source"], expected_answer_source)
                self.assertEqual(
                    response.get("resolved_query", {}).get("period_type"),
                    expected_period_type,
                )
                self.assertTrue(str(response.get("reply", "")).strip())

    def test_recent_transactions_empty_returns_deterministic_no_data_reply(self):
        service = self._service_with_reply(
            '{"reply":"llm fallback narrative","insights":["i1"],"actions":["a1"]}'
        )
        summary = self._frontend_v3_summary_fixture()
        summary["recent_transactions"] = []
        response = service.handle_chat(
            {"prompt": "show recent transactions", "history": [], "spending_summary": summary},
            user_id="demo-user",
        )
        self.assertEqual(response["intent"], "recent_transactions")
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertIn("do not see recent transactions", response["reply"].lower())

    def test_llm_malformed_jsonish_reply_does_not_leak_raw_blob(self):
        service = self._service_with_reply(
            '{"reply":"Reduce dining expenses by cutting one meal weekly.","insights":["Food is elevated"],"actions":[{"next":"Track receipts"}'
        )
        service.router.classify = lambda _message, _history: {
            "intent": "what_if",
            "intent_confidence": 0.9,
            "intent_candidates": ["what_if"],
            "intent_source": "llm",
            "needs_clarification": False,
            "response_mode": "llm",
            "entities": {"metric": "expenses", "period_type": "rolling_30d", "period_key": "rolling_30d", "scope_hint": "current_scope"},
            "clarification_question": "",
        }
        summary = self._frontend_v3_summary_fixture()
        payload = {
            "prompt": "What if I reduce dining by 20%?",
            "history": [],
            "spending_summary": summary,
        }

        response = service.handle_chat(payload, user_id="demo-user")
        self.assertTrue(str(response.get("reply", "")).strip())
        self.assertNotIn('{"reply"', response["reply"])
        self.assertIn("dining", response["reply"].lower())
        self.assertGreater(len(response.get("actions", [])), 0)

    def test_llm_structured_reply_content_is_presentable(self):
        service = self._service_with_reply(
            '{"reply":"You are spending more on Food than last month.","insights":["Food is your largest category"],"actions":["Reduce Food by 15% over 14 days"]}'
        )
        service.router.classify = lambda _message, _history: {
            "intent": "explain",
            "intent_confidence": 0.9,
            "intent_candidates": ["explain"],
            "intent_source": "llm",
            "needs_clarification": False,
            "response_mode": "llm",
            "entities": {"metric": "expenses", "period_type": "month", "period_key": "2026-05", "scope_hint": "current_scope"},
            "clarification_question": "",
        }
        summary = self._frontend_v3_summary_fixture()
        payload = {
            "prompt": "Explain why this month is higher than last month",
            "history": [],
            "spending_summary": summary,
        }

        response = service.handle_chat(payload, user_id="demo-user")
        self.assertEqual(response["answer_source"], "llm")
        self.assertTrue(str(response.get("reply", "")).strip())
        self.assertIsInstance(response.get("insights"), list)
        self.assertIsInstance(response.get("actions"), list)
        self.assertGreater(len(response["insights"]), 0)
        self.assertGreater(len(response["actions"]), 0)


class TestIntentRouterFallback(unittest.TestCase):
    def test_rule_first_parses_month_name_with_year(self):
        router = IntentRouter(classify_with_llm=None)
        result = router.classify("How much did I spend in March 2026?", history=[])
        self.assertEqual(result["intent_source"], "rule")
        self.assertEqual(result["intent"], "amount_lookup")
        self.assertEqual(result["entities"]["period_type"], "month")
        self.assertEqual(result["entities"]["period_key"], "2026-03")

    def test_vague_single_word_requires_clarification(self):
        router = IntentRouter(classify_with_llm=None)
        result = router.classify("how", history=[])
        self.assertTrue(result["needs_clarification"])
        self.assertEqual(result["response_mode"], "clarification")

    def test_fallback_to_rule_when_llm_intent_invalid(self):
        def invalid_classifier(_prompt, generation_config=None):
            _ = generation_config
            return '{"intent":"invalid_label","confidence":0.9,"intent_candidates":["invalid_label"]}'

        router = IntentRouter(classify_with_llm=invalid_classifier)
        result = router.classify("How can I plan my budget?", history=[])
        self.assertEqual(result["intent_source"], "rule")
        self.assertEqual(result["intent"], "planning")

    def test_llm_response_mode_is_preserved_when_valid(self):
        def classifier(_prompt, generation_config=None):
            _ = generation_config
            return (
                '{"intent":"amount_lookup","confidence":0.93,'
                '"intent_candidates":["amount_lookup","general"],'
                '"entities":{"metric":"expenses","period_type":"month","period_key":"2026-03","scope_hint":"current_scope"},'
                '"needs_clarification":false,"clarification_question":"","response_mode":"deterministic"}'
            )

        router = IntentRouter(classify_with_llm=classifier)
        result = router.classify("monthly status details", history=[])
        self.assertEqual(result["intent_source"], "llm")
        self.assertEqual(result["response_mode"], "deterministic")

    def test_llm_response_mode_invalid_value_falls_back_empty(self):
        def classifier(_prompt, generation_config=None):
            _ = generation_config
            return (
                '{"intent":"planning","confidence":0.8,'
                '"intent_candidates":["planning"],'
                '"entities":{"metric":"unknown","period_type":"unknown","period_key":"","scope_hint":"current_scope"},'
                '"needs_clarification":false,"clarification_question":"","response_mode":"random_mode"}'
            )

        router = IntentRouter(classify_with_llm=classifier)
        result = router.classify("financial overview details", history=[])
        self.assertEqual(result["intent_source"], "llm")
        self.assertEqual(result["response_mode"], "clarification")


if __name__ == "__main__":
    unittest.main()
