"""Plaid sign convention: a positive amount is money out (expense), negative is money in."""

import unittest

from ai.chat_service import ChatService
from ai.query_executors_v2 import _exec_recent_transactions
from ai.response_utils import describe_plaid_amount

SUMMARY = {
    "scope_label": "Overall (All Accounts)",
    "totals": {"income_30d": 1200, "expenses_30d": 50},
    "recent_transactions": [
        {"date": "2026-10-02", "name": "Coffee Shop", "amount": 50.0},
        {"date": "2026-10-01", "name": "Payroll", "amount": -1200.0},
    ],
}


def _service():
    return ChatService(
        generate_reply=lambda prompt, generation_config=None: "",
        get_detailed_snapshot=lambda user_id: "",
    )


class DescribePlaidAmountTests(unittest.TestCase):
    def test_positive_is_spent_and_negative_is_received(self):
        self.assertEqual(describe_plaid_amount(50), "spent $50.00")
        self.assertEqual(describe_plaid_amount(-1200), "received $1200.00")
        self.assertEqual(describe_plaid_amount(0), "$0.00")
        self.assertEqual(describe_plaid_amount(None), "$0.00")


class RecentTransactionTextTests(unittest.TestCase):
    def _assert_labelled(self, text):
        self.assertIn("Coffee Shop spent $50.00", text)
        self.assertIn("Payroll received $1200.00", text)
        self.assertNotIn("+$50", text)
        self.assertNotIn("-$1200", text)
        self.assertNotIn("$-1200", text)

    def test_chat_anchor_labels_direction(self):
        self._assert_labelled(_service()._recent_transactions_anchor(SUMMARY))

    def test_v2_executor_labels_direction(self):
        self._assert_labelled(_exec_recent_transactions(SUMMARY, "Overall")["reply"])

    def test_llm_context_labels_direction(self):
        self._assert_labelled(_service()._summary_to_text(SUMMARY))


if __name__ == "__main__":
    unittest.main()
