import json
import unittest
from pathlib import Path

from budget_progress import (
    budget_bucket_for_row,
    build_budget_progress,
    counts_as_spending,
    is_expense_row,
    row_kind,
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
                if "kind" in expected:
                    self.assertEqual(row_kind(row), expected["kind"])

    def test_month_progress(self):
        for case in ("progress", "progress_unbudgeted"):
            with self.subTest(case):
                spec = FIXTURE[case]
                progress = build_budget_progress(
                    budget_rows=spec["budgets"],
                    category_names_by_id=spec["categories"],
                    tx_rows=spec["transactions"],
                    remembered_rules=FIXTURE["rules"],
                    month=spec["month"],
                )
                actual = [
                    {k: item[k] for k in ("category_id", "category", "spent", "limit")}
                    for item in progress
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


class OwnTransferPairingTests(unittest.TestCase):
    def test_same_amount_between_linked_accounts_is_internal(self):
        from budget_progress import classify_rows

        def row(tid, account, amount, name, primary, day):
            return {
                "plaid_transaction_id": tid,
                "plaid_account_id": account,
                "amount": amount,
                "date": day,
                "name": name,
                "merchant_name": None,
                "pfc_primary": primary,
                "pfc_detailed": "",
            }

        rows = [
            row("out", "checking", 300, "WITHDRAWAL 10/14", "TRANSFER_OUT", "2026-10-14"),
            row("in", "savings", -300, "DEPOSIT", "TRANSFER_IN", "2026-10-15"),
            row("lunch", "checking", 20, "Chipotle", "FOOD_AND_DRINK", "2026-10-14"),
            row(
                "friend", "savings", -20, "Zelle payment from ALICE HU", "TRANSFER_IN", "2026-10-14"
            ),
        ]
        kinds = {k: v[0] for k, v in classify_rows(rows, {}).items()}
        self.assertEqual(
            kinds, {"out": "internal", "in": "internal", "lunch": "spend", "friend": "income"}
        )
