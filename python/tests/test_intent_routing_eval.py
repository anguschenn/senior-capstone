import unittest
from collections import defaultdict

from ai.intent_router import IntentRouter


class TestIntentRoutingEval(unittest.TestCase):
    """Lightweight evaluation harness for intent routing quality."""

    def test_rule_fallback_eval_report(self):
        router = IntentRouter(classify_with_llm=None)
        dataset = [
            ("How much did I spend in 2026-04?", "amount_lookup"),
            ("What did I spend on 2026-04-21?", "general"),
            ("Which category was highest in April 2026?", "top_category_lookup"),
            ("How much did I spend this year?", "amount_lookup"),
            ("Compare spending for 2026-01 and 2026-03", "general"),
            ("Compare yearly expenses: 2024 vs 2025.", "general"),
            ("Explain the increase in spending this month.", "explain"),
            ("Why are costs higher after March?", "explain"),
            ("What if I lower dining spend by 15%?", "what_if"),
            ("If I trim shopping, what changes?", "what_if"),
            ("How should I budget for next month?", "planning"),
            ("Create a spending plan for May.", "planning"),
            ("Can you review my spending health?", "explain"),
            ("Any budgeting tips for me?", "general"),
        ]
        confusion = defaultdict(lambda: defaultdict(int))
        clarifications = 0
        correct = 0
        for text, expected in dataset:
            result = router.classify(text, history=[])
            predicted = result.get("intent", "general")
            confusion[expected][predicted] += 1
            if result.get("needs_clarification"):
                clarifications += 1
            if predicted == expected:
                correct += 1
        accuracy = correct / len(dataset)
        clarification_rate = clarifications / len(dataset)
        print(f"[intent-eval] samples={len(dataset)} accuracy={accuracy:.3f} clarification_rate={clarification_rate:.3f}")
        for expected in sorted(confusion.keys()):
            row = ", ".join(f"{pred}:{count}" for pred, count in sorted(confusion[expected].items()))
            print(f"[intent-eval] expected={expected} -> {row}")
        self.assertGreaterEqual(accuracy, 0.75)

    def test_edge_cases_for_conservative_routing(self):
        router = IntentRouter(classify_with_llm=None)
        cases = [
            # amount queries across period variants
            ("How much did I spend this month?", "amount_lookup", False),
            ("How much did I spend this year so far?", "amount_lookup", False),
            ("Total spending over the last 7 days?", "amount_lookup", False),
            ("Total spending over the last 52 days?", "amount_lookup", False),
            ("How much was spent in 2026-04?", "amount_lookup", False),
            # top/recent deterministic families
            ("What is my top category?", "top_category_lookup", False),
            ("What category did I spend most on last month?", "top_category_lookup", False),
            ("List my latest transactions", "recent_transactions", False),
            # mixed intent should avoid deterministic misroute
            ("Top category this month and how do I reduce it?", "general", True),
            ("Show latest transactions and give optimization advice", "general", True),
            ("What is this month spending and why did it rise?", "general", True),
            # ambiguous / underspecified prompts should clarify
            ("What is my spending total?", "general", True),
            ("compare 2026-01 vs 2026-02", "general", True),
            ("expense status?", "general", True),
            # extreme period text should still classify conservatively
            ("How much did I spend in the last 500 days?", "amount_lookup", False),
            ("How much did I spend in the last -3 days?", "general", True),
        ]
        for text, expected_intent, expected_clarify in cases:
            with self.subTest(text=text):
                result = router.classify(text, history=[])
                self.assertEqual(result.get("intent"), expected_intent)
                self.assertEqual(bool(result.get("needs_clarification")), expected_clarify)

    def test_edge_cases_for_noisy_inputs_batch_2(self):
        router = IntentRouter(classify_with_llm=None)
        cases = [
            ("spent this month?", "amount_lookup", False),
            ("THIS YEAR spend total", "amount_lookup", False),
            ("recent tx", "recent_transactions", False),
            ("latest transactions", "recent_transactions", False),
            ("top category rn", "top_category_lookup", False),
            ("top category... why high", "explain", False),
            ("how much did i spend 2026-05", "amount_lookup", False),
            ("last 30 days spending", "amount_lookup", False),
            ("2026-05 total?", "general", True),
            ("need advice cut costs", "general", True),
            ("last 365 days spend", "amount_lookup", False),
            ("last -2 days spend", "general", True),
        ]
        for text, expected_intent, expected_clarify in cases:
            with self.subTest(text=text):
                result = router.classify(text, history=[])
                self.assertEqual(result.get("intent"), expected_intent)
                self.assertEqual(bool(result.get("needs_clarification")), expected_clarify)

    def test_edge_cases_for_noisy_inputs_batch_3(self):
        router = IntentRouter(classify_with_llm=None)
        cases = [
            ("spending 2026-05?", "amount_lookup", False),
            ("how is my spending last month", "amount_lookup", False),
            ("analyst my spending last month", "explain", False),
            ("2026-05 spending why up", "explain", False),
            ("recent tx and top category", "general", True),
            ("top category 2026/05", "top_category_lookup", False),
            ("show me latest tx for last week", "recent_transactions", False),
            ("how much did i spend this week", "amount_lookup", False),
            ("how much did i spend this wk?", "amount_lookup", False),
            ("compare 2026-05 and 2026-04 and suggest plan", "general", True),
            ("income this month", "general", True),
            ("net this month", "general", True),
            ("how much did i spend in 2026/13", "general", True),
            ("latest transactions for 2026-05 and advice", "general", True),
        ]
        for text, expected_intent, expected_clarify in cases:
            with self.subTest(text=text):
                result = router.classify(text, history=[])
                self.assertEqual(result.get("intent"), expected_intent)
                self.assertEqual(bool(result.get("needs_clarification")), expected_clarify)

    def test_edge_cases_requested_batch_4(self):
        router = IntentRouter(classify_with_llm=None)
        cases = [
            ("How much last month?", "general", True),
            ("Analyze my spending last month", "explain", False),
            ("analyst my spending last month", "explain", False),
            ("How much did I spend in 2026/13?", "general", True),
            ("Top category this month and how can I reduce it?", "general", True),
            ("Show recent transactions for last week and explain trend", "general", True),
            ("last 30 days spending", "amount_lookup", False),
            ("last 30 day spend", "amount_lookup", False),
            ("last30d spending", "amount_lookup", False),
            ("How much did I spend last monthne", "general", True),
            ("how much i spend this month? income", "general", True),
            ("which month did I spend the most this year?", "month_overview", False),
        ]
        for text, expected_intent, expected_clarify in cases:
            with self.subTest(text=text):
                result = router.classify(text, history=[])
                self.assertEqual(result.get("intent"), expected_intent)
                self.assertEqual(bool(result.get("needs_clarification")), expected_clarify)


if __name__ == "__main__":
    unittest.main()
