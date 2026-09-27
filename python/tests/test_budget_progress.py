import json
import unittest
from pathlib import Path

from budget_progress import (
    budget_bucket_for_row,
    build_budget_progress,
    counts_as_spending,
    is_expense_row,
    rule_key_for_row,
)

# Shared with ssdemo_1/test/services/budget_bucket_contract_test.dart — both must pass.
FIXTURE = json.loads(
    (Path(__file__).parent / "data" / "budget_bucket_contract.json").read_text(encoding="utf-8")
)


class BudgetBucketContractTests(unittest.TestCase):
    def test_transaction_cases(self):
        rules = FIXTURE["rules"]
        for case in FIXTURE["transactions"]:
            with self.subTest(case["description"]):
                row, expected = case["row"], case["expected"]
                self.assertEqual(rule_key_for_row(row), expected["rule_key"])
                self.assertEqual(budget_bucket_for_row(row, rules), expected["bucket"])
                self.assertEqual(is_expense_row(row), expected["is_expense"])
                self.assertEqual(counts_as_spending(row), expected["counts_as_spending"])

    def test_month_progress(self):
        spec = FIXTURE["progress"]
        progress = build_budget_progress(
            budget_rows=spec["budgets"],
            category_names_by_id=spec["categories"],
            tx_rows=spec["transactions"],
            remembered_rules=FIXTURE["rules"],
            month=spec["month"],
        )
        actual = [
            {k: item[k] for k in ("category_id", "category", "spent", "limit")} for item in progress
        ]
        self.assertEqual(actual, spec["expected"])

    def test_progress_feeds_burn_rate_check(self):
        """Output shape is what PredictService's burn-rate check sanitizes and reads."""
        from ai.validators import sanitize_budget_progress

        spec = FIXTURE["progress"]
        progress = build_budget_progress(
            spec["budgets"], spec["categories"], spec["transactions"], FIXTURE["rules"], "2026-09"
        )
        cleaned = sanitize_budget_progress(progress)
        self.assertEqual(len(cleaned), len(progress))
        food = next(item for item in cleaned if item["category"] == "Food")
        self.assertAlmostEqual(food["ratio"], 278.25 / 300, places=3)


if __name__ == "__main__":
    unittest.main()
