import unittest
from unittest import mock

from ai import question_log


class MaskQuestionTests(unittest.TestCase):
    def test_amounts_long_numbers_and_emails_are_masked(self):
        cases = [
            ("Can I afford a $1,200 laptop?", "Can I afford a [amount] laptop?"),
            ("did I spend over 300 dollars on food", "did I spend over [amount] on food"),
            ("is account 123456789 mine", "is account [number] mine"),
            ("email me at sam@example.com", "email me at [email]"),
            ("How much did I spend on Oct 12 2026?", "How much did I spend on Oct 12 2026?"),
        ]
        for text, expected in cases:
            with self.subTest(text=text):
                self.assertEqual(question_log.mask_question(text), expected)

    def test_long_questions_are_cut(self):
        self.assertEqual(len(question_log.mask_question("a" * 1000)), 300)


class ClassifyTests(unittest.TestCase):
    def test_outcomes(self):
        cases = [
            ({"reply": "For 2026-09, total expenses are about $1940."}, ("answered", "")),
            ({"reply": 'I read this as "How much did I spend?" For ...'}, ("rewritten", "")),
            (
                {
                    "reply": "For 2026-10 ... Note: this answer doesn't cover net cash flow. "
                    "If that's what you meant, ask about it on its own."
                },
                ("partial", "net cash flow"),
            ),
            ({"reply": "Please clarify.", "answer_source": "clarification"}, ("unclear", "")),
            ({"context_source": "rule_fallback"}, ("error", "")),
        ]
        for response, expected in cases:
            with self.subTest(response=response):
                self.assertEqual(question_log.classify(response), expected)

    def test_row_keeps_no_reply_amounts(self):
        row = question_log.question_row(
            "Did I spend over $500 in August?",
            {
                "reply": "Yes. You spent $3286.",
                "intent": "amount_lookup",
                "answer_source": "deterministic",
            },
        )
        self.assertEqual(row["question"], "Did I spend over [amount] in August?")
        self.assertNotIn("3286", str(row))
        self.assertEqual(set(row), {"question", "intent", "answer_source", "outcome", "missing"})

    def test_rows_are_appended_to_the_log_file(self):
        import json
        import os
        import tempfile

        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "logs", "q.jsonl")
            with mock.patch.object(question_log, "LOG_PATH", path):
                question_log.record_question("Can I afford a $400 phone?", {"reply": "Likely yes."})
                question_log.record_question("hi", {"reply": "Hi"})
            rows = [json.loads(line) for line in open(path)]
        self.assertEqual([r["question"] for r in rows], ["Can I afford a [amount] phone?", "hi"])
        self.assertTrue(all(r["asked_at"] for r in rows))

    def test_write_failures_are_swallowed(self):
        with mock.patch.object(question_log, "LOG_PATH", "/dev/null/nope/q.jsonl"):
            question_log.record_question("hello", {"reply": "Hi"})
