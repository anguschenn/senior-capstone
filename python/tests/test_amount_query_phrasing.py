"""Spending questions phrased with have/may/might still route to the deterministic lookup."""

import unittest

from ai.intent_router import IntentRouter


def _router():
    # The LLM fallback must not be reached for these; fail loudly if it is.
    def classify_with_llm(prompt, generation_config=None):
        raise AssertionError("LLM fallback used for a plain amount question")

    return IntentRouter(classify_with_llm=classify_with_llm)


class AmountQueryPhrasingTests(unittest.TestCase):
    def test_modal_and_perfect_phrasings_route_to_amount_lookup(self):
        for text in (
            "what may I have spent in june",
            "What have I spent in June 2026?",
            "what might i have spent in june",
            "what did I spend in june",
        ):
            with self.subTest(text):
                result = _router().classify(text)
                self.assertEqual(result["intent"], "amount_lookup")
                self.assertEqual(result["entities"]["period_type"], "month")
                self.assertTrue(result["entities"]["period_key"].endswith("-06"))


if __name__ == "__main__":
    unittest.main()
