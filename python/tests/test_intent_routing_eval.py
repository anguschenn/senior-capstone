import unittest
from collections import defaultdict

from ai.intent_router import IntentRouter


class TestIntentRoutingEval(unittest.TestCase):
    """Lightweight evaluation harness for intent routing quality."""

    def test_rule_fallback_eval_report(self):
        router = IntentRouter(classify_with_llm=None)
        dataset = [
            ("How much did I spend in 2026-03?", "amount_lookup"),
            ("How much did I spend on 2026-03-15?", "amount_lookup"),
            ("What category did I spend most on in March 2026?", "top_category_lookup"),
            ("Which month did I spend the most this year?", "month_overview"),
            ("Compare my spending in 2026-02 vs 2026-03", "compare_periods"),
            ("Compare 2025 vs 2026 expenses.", "compare_periods"),
            ("Explain why spending increased this month.", "explain"),
            ("Why did my expenses jump after February?", "explain"),
            ("What if I cut dining by 20%?", "what_if"),
            ("If I reduce shopping, what happens?", "what_if"),
            ("How should I plan next month budget?", "planning"),
            ("Give me a budget roadmap for April.", "planning"),
            ("Can you help me with my finances?", "general"),
            ("Any advice?", "general"),
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


if __name__ == "__main__":
    unittest.main()
