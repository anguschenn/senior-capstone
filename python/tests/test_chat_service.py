import unittest
from datetime import date as date_cls

from ai.chat_service import ChatService
from ai.intent_router import IntentRouter


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
        self.assertIn("citations", response)
        self.assertEqual(response["reply"], "You are trending within budget.")
        self.assertEqual(response["insights"], ["30d expenses are stable"])
        self.assertIn("Keep weekly check-ins", response["actions"])

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
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertEqual(response["resolved_query"]["intent"], "amount_lookup")
        self.assertEqual(response["resolved_query"]["period_type"], "day")
        self.assertEqual(response["resolved_query"]["period_key"], "2026-03-15")
        self.assertIn("2026-03-15", response["reply"])
        self.assertIn("$25", response["reply"])

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
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertEqual(response["resolved_query"]["intent"], "month_overview")
        self.assertIn("2026-01", response["reply"])
        self.assertIn("$500", response["reply"])
        self.assertNotIn("$1200", response["reply"])

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
        self.assertEqual(response["resolved_query"]["intent"], "amount_lookup")
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
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertIn("Comparing 2026-02 vs 2026-03", response["reply"])
        self.assertIn("$200", response["reply"])
        self.assertIn("$300", response["reply"])
        self.assertIn("$100", response["reply"])

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
        self.assertEqual(response["answer_source"], "clarification")
        self.assertIn("summary_data_for_period", " ".join(response["missing_fields"]))

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
        self.assertEqual(response["answer_source"], "deterministic")
        self.assertIn("total expenses", response["reply"].lower())
        self.assertIn("to", response["reply"])

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


class TestIntentRouterFallback(unittest.TestCase):
    def test_fallback_to_rule_when_llm_intent_invalid(self):
        def invalid_classifier(_prompt, generation_config=None):
            _ = generation_config
            return '{"intent":"invalid_label","confidence":0.9,"intent_candidates":["invalid_label"]}'

        router = IntentRouter(classify_with_llm=invalid_classifier)
        result = router.classify("How can I plan my budget?", history=[])
        self.assertEqual(result["intent_source"], "rule")
        self.assertIn(result["intent"], {"planning", "general"})

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
        result = router.classify("How much did I spend in 2026-03?", history=[])
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
        result = router.classify("Help me plan my spending", history=[])
        self.assertEqual(result["intent_source"], "llm")
        self.assertEqual(result["response_mode"], "")


if __name__ == "__main__":
    unittest.main()
