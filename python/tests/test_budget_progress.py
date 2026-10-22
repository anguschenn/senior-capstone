import json
import unittest
import unittest.mock
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

    def test_paybacks_and_shared_purchases(self):
        from budget_progress import classify_rows

        spec = FIXTURE["progress_paybacks"]
        decided = classify_rows(spec["transactions"], spec["rules"], decisions=spec["decisions"])
        self.assertEqual({k: v.kind for k, v in decided.items()}, spec["expected_kinds"])
        self.assertEqual(
            {k: v.paid_back for k, v in decided.items() if v.paid_back}, spec["expected_paid_back"]
        )
        progress = build_budget_progress(
            spec["budgets"],
            spec["categories"],
            spec["transactions"],
            spec["rules"],
            spec["month"],
            decisions=spec["decisions"],
        )
        actual = [
            {k: item[k] for k in ("category_id", "category", "spent", "limit")} for item in progress
        ]
        self.assertEqual(actual, spec["expected"])

    def test_classify_cases(self):
        """Whole-list decisions (own-account pairs, refunds, paybacks) the app must match:
        each case's kinds, paid-back amounts, income and month spending."""
        from ai.server_summary import build_transactions

        for case in FIXTURE["classify_cases"]:
            with self.subTest(case["_comment"]):
                txs = {
                    tx.id: tx
                    for tx in build_transactions(
                        case["transactions"], {}, case["rules"], decisions=case["decisions"]
                    )
                }
                kinds = {tx_id: txs[tx_id].kind for tx_id in case["expected_kinds"]}
                self.assertEqual(kinds, case["expected_kinds"])
                for tx_id, amount in case.get("expected_paid_back", {}).items():
                    self.assertAlmostEqual(txs[tx_id].paid_back, amount, places=2)
                for tx_id, amount in case.get("expected_income", {}).items():
                    self.assertAlmostEqual(txs[tx_id].income_amount, amount, places=2)
                progress = build_budget_progress(
                    case["budgets"],
                    case["categories"],
                    case["transactions"],
                    case["rules"],
                    case["month"],
                    decisions=case["decisions"],
                )
                actual = [
                    {k: item[k] for k in ("category_id", "category", "spent", "limit")}
                    for item in progress
                ]
                self.assertEqual(actual, case["expected"])

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

    def test_a_transaction_stored_twice_counts_once(self):
        spec = FIXTURE["progress"]

        def food_spent(rows):
            progress = build_budget_progress(
                spec["budgets"], spec["categories"], rows, FIXTURE["rules"], spec["month"]
            )
            return next(item["spent"] for item in progress if item["category"] == "Food")

        coffee = next(r for r in spec["transactions"] if r["plaid_transaction_id"] == "tx-1")
        once = food_spent(spec["transactions"])
        self.assertEqual(food_spent(spec["transactions"] + [dict(coffee)]), once)


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


class PairingEdgeTests(unittest.TestCase):
    def _row(self, tid, account, amount, day):
        return {
            "plaid_transaction_id": tid,
            "plaid_account_id": account,
            "amount": amount,
            "date": day,
            "name": "ONLINE TRANSFER",
            "merchant_name": None,
            "pfc_primary": "TRANSFER_OUT" if amount > 0 else "TRANSFER_IN",
            "pfc_detailed": "",
        }

    def test_each_move_pairs_with_the_closest_arrival_in_any_order(self):
        from budget_progress import classify_rows

        rows = [
            self._row("in-late", "savings", -500, "2026-10-12"),
            self._row("out-2", "checking", 500, "2026-10-11"),
            self._row("in-early", "savings", -500, "2026-10-02"),
            self._row("out-1", "checking", 500, "2026-10-01"),
            self._row("out-3", "checking", 500, "2026-10-20"),
        ]
        for order in (rows, list(reversed(rows))):
            kinds = {k: v[0] for k, v in classify_rows(order, {}).items()}
            self.assertEqual(kinds["out-1"], "internal")
            self.assertEqual(kinds["out-2"], "internal")
            self.assertEqual(kinds["out-3"], "spend")

    def test_a_late_payback_still_lowers_its_purchase(self):
        """A friend pays back a September dinner in November: September's budget fetch
        reaches the payment through the user's link."""
        from fake_supabase import FakeSupabase

        import budget_progress

        def row(tx_id, day, name, amount, primary):
            return {
                "user_id": "u1",
                "plaid_transaction_id": tx_id,
                "plaid_account_id": "acc-1",
                "amount": amount,
                "date": day,
                "name": name,
                "merchant_name": None,
                "category": None,
                "pfc_primary": primary,
                "pfc_detailed": "",
            }

        db = FakeSupabase(
            {
                "transactions": [
                    row("dinner", "2026-09-28", "Olive Garden", 80, "FOOD_AND_DRINK"),
                    row("amy", "2026-11-20", "Zelle payment from Amy", -40, "TRANSFER_IN"),
                ],
                "transaction_decisions": [
                    {
                        "user_id": "u1",
                        "plaid_transaction_id": "amy",
                        "paid_back_purchase_id": "dinner",
                    }
                ],
                "budgets": [
                    {
                        "user_id": "u1",
                        "id": "b1",
                        "category_id": "c-food",
                        "monthly_limit": 300,
                        "month_year": "2026-09",
                    }
                ],
                "categories": [{"id": "c-food", "name": "Food", "user_id": None}],
                "category_match_rules": [],
                "accounts": [],
            }
        )
        with unittest.mock.patch.object(budget_progress, "supabase", db):
            progress = budget_progress.compute_budget_progress("u1", "2026-09")
        self.assertEqual(progress[0]["spent"], 40.0)

    def test_decisions_are_empty_before_the_migration(self):
        import budget_progress

        with unittest.mock.patch.object(budget_progress, "supabase") as db:
            db.table.side_effect = RuntimeError("relation does not exist")
            self.assertEqual(budget_progress.fetch_decisions("u1"), {})

    def test_month_end_fetch_reaches_into_the_next_month(self):
        import budget_progress

        with unittest.mock.patch.object(budget_progress, "supabase") as db:
            query = db.table.return_value.select.return_value.eq.return_value.gte.return_value
            query.lt.return_value.order.return_value.range.return_value.execute.return_value.data = []
            budget_progress._fetch_month_transactions("u1", "2026-10")
            query.lt.assert_called_once_with("date", "2026-11-06")
