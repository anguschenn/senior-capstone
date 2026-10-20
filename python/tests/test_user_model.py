import datetime as dt
import unittest
from unittest import mock

from fake_supabase import FakeSupabase

import user_model

USER = "user-1"
TODAY = dt.date(2026, 10, 10)  # day 10 of 31


def food(date, amount, name="Chipotle"):
    return {
        "plaid_transaction_id": f"food-{date}-{amount}",
        "plaid_account_id": "acc-1",
        "amount": amount,
        "date": date,
        "name": name,
        "merchant_name": name,
        "pfc_primary": "FOOD_AND_DRINK",
        "pfc_detailed": "FOOD_AND_DRINK_RESTAURANT",
    }


def shop(date, amount):
    return {
        "plaid_transaction_id": f"shop-{date}-{amount}",
        "plaid_account_id": "acc-1",
        "amount": amount,
        "date": date,
        "name": "Amazon",
        "merchant_name": "Amazon",
        "pfc_primary": "GENERAL_MERCHANDISE",
        "pfc_detailed": "GENERAL_MERCHANDISE_ONLINE_MARKETPLACES",
    }


def other(date, amount):
    return {
        "plaid_transaction_id": f"other-{date}-{amount}",
        "plaid_account_id": "acc-1",
        "amount": amount,
        "date": date,
        "name": "Mystery",
    }


CATEGORIES = {"cat-food": "Food", "cat-shop": "Shopping", "cat-other": "Other"}
BUDGETS = [
    {"id": "b-food", "category_id": "cat-food", "monthly_limit": 300},
    {"id": "b-shop", "category_id": "cat-shop", "monthly_limit": 100},
    {"id": "b-other", "category_id": "cat-other", "monthly_limit": 50},
]
# Food Apr..Sep: 200, 250, 260, 240, 900, 100 -> trimmed mean 237.5 -> $240.
HISTORY = [
    food("2026-04-05", 200),
    food("2026-05-05", 250),
    food("2026-06-05", 260),
    food("2026-07-05", 240),
    food("2026-08-05", 900),
    food("2026-09-05", 100),
] + [shop(f"2026-{m:02d}-07", 100) for m in range(4, 10)]
OCTOBER = [
    food("2026-10-02", 90),
    food("2026-10-08", 60),  # Food 150 by day 10 -> projects 465 > 300
    shop("2026-10-03", 120),  # Shopping 120 > 100
    other("2026-10-04", 15),  # Other 15 -> projects 46.5, >= 90% of 50
    {**food("2026-10-05", 40), "pfc_detailed": "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"},
]


class CategoryMonthStatsTests(unittest.TestCase):
    def test_spend_per_month_and_bucket(self):
        stats = user_model.build_category_month_stats(HISTORY + OCTOBER, {})
        by_key = {(s["month"], s["category"]): s for s in stats}
        self.assertEqual(by_key[("2026-10", "Food")], {**by_key[("2026-10", "Food")], "spent": 150})
        self.assertEqual(by_key[("2026-10", "Food")]["tx_count"], 2)
        self.assertEqual(by_key[("2026-10", "Shopping")]["spent"], 120)
        self.assertEqual(by_key[("2026-10", "Other")]["spent"], 15)
        self.assertEqual(by_key[("2026-08", "Food")]["spent"], 900)

    def test_card_payments_and_inflows_are_not_spending(self):
        rows = [
            {**food("2026-10-05", 40), "pfc_detailed": "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"},
            food("2026-10-06", -25),
        ]
        self.assertEqual(user_model.build_category_month_stats(rows, {}), [])

    def test_remembered_rule_wins(self):
        rule_key = "chipotle|food and drink|food and drink restaurant"
        stats = user_model.build_category_month_stats(
            [food("2026-10-02", 10)], {rule_key: "Entertainment"}
        )
        self.assertEqual(stats[0]["category"], "Entertainment")


class AlertTests(unittest.TestCase):
    def test_thresholds_match_the_budget_page(self):
        cases = [
            (120, 100, "over_budget"),
            (150, 300, "projected_over"),  # 465 projected
            (15, 50, "approaching"),  # 46.5 projected
            (10, 50, None),  # 31 projected
            (0, 50, None),
            (40, 0, None),  # no limit set
        ]
        for spent, limit, expected in cases:
            with self.subTest(spent=spent, limit=limit):
                found = user_model.alert_kind(spent, limit, TODAY)
                self.assertEqual(found[0] if found else None, expected)

    def test_build_alerts_from_progress(self):
        from budget_progress import build_budget_progress

        progress = build_budget_progress(BUDGETS, CATEGORIES, HISTORY + OCTOBER, {}, "2026-10")
        alerts = {a["category"]: a for a in user_model.build_alerts(progress, TODAY)}
        self.assertEqual(alerts["Food"]["kind"], "projected_over")
        self.assertEqual(alerts["Food"]["projected_month_end"], 465.0)
        self.assertEqual(alerts["Shopping"]["kind"], "over_budget")
        self.assertEqual(alerts["Shopping"]["used_ratio"], 1.2)
        self.assertEqual(alerts["Other"]["kind"], "approaching")


class SuggestionTests(unittest.TestCase):
    def test_trimmed_mean_drops_high_and_low(self):
        self.assertEqual(user_model.trimmed_mean([200, 250, 260, 240, 900, 100]), 237.5)
        self.assertEqual(user_model.trimmed_mean([10, 20]), 15)

    def test_suggests_only_meaningful_changes(self):
        suggestions = user_model.build_suggestions(
            BUDGETS, CATEGORIES, HISTORY + OCTOBER, {}, "2026-10"
        )
        by_category = {s["category"]: s for s in suggestions}
        # Food: 300 -> 240. Shopping matches its limit. Other: no history, so no $0 ask.
        self.assertEqual(set(by_category), {"Food"})
        food_suggestion = by_category["Food"]
        self.assertEqual(food_suggestion["suggested_limit"], 240.0)
        self.assertEqual(food_suggestion["current_limit"], 300.0)
        self.assertEqual(food_suggestion["budget_id"], "b-food")
        self.assertEqual(
            food_suggestion["basis"]["months"],
            ["2026-04", "2026-05", "2026-06", "2026-07", "2026-08", "2026-09"],
        )

    def test_small_changes_are_not_asked(self):
        budgets = [{"id": "b-food", "category_id": "cat-food", "monthly_limit": 245}]
        self.assertEqual(
            user_model.build_suggestions(budgets, CATEGORIES, HISTORY, {}, "2026-10"), []
        )

    def test_needs_three_months_of_history(self):
        rows = [food("2026-08-05", 100), food("2026-09-05", 100)]
        self.assertEqual(user_model.build_suggestions(BUDGETS, CATEGORIES, rows, {}, "2026-10"), [])


class WriteTests(unittest.TestCase):
    def setUp(self):
        self.db = FakeSupabase()
        patcher = mock.patch.object(user_model, "supabase", self.db)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _alert(self, kind, category_id="cat-food"):
        return {
            "category_id": category_id,
            "category": "Food",
            "kind": kind,
            "spent": 1,
            "limit_amount": 1,
            "projected_month_end": 1,
            "used_ratio": 1,
        }

    def test_alerts_keep_a_dismissal_until_they_escalate(self):
        user_model.write_alerts(USER, "2026-10", [self._alert("approaching")])
        self.db.tables["budget_alerts"][0]["dismissed_at"] = "2026-10-10T00:00:00+00:00"

        user_model.write_alerts(USER, "2026-10", [self._alert("approaching")])
        self.assertEqual(len(self.db.tables["budget_alerts"]), 1)
        self.assertIsNotNone(self.db.tables["budget_alerts"][0]["dismissed_at"])

        user_model.write_alerts(USER, "2026-10", [self._alert("over_budget")])
        row = self.db.tables["budget_alerts"][0]
        self.assertEqual(row["kind"], "over_budget")
        self.assertIsNone(row["dismissed_at"])

    def test_alert_that_clears_is_resolved(self):
        user_model.write_alerts(USER, "2026-10", [self._alert("approaching")])
        user_model.write_alerts(USER, "2026-10", [])
        self.assertIsNotNone(self.db.tables["budget_alerts"][0]["resolved_at"])

    def test_decided_suggestions_are_never_rewritten(self):
        self.db.tables["budget_suggestions"] = [
            {
                "id": "s1",
                "user_id": USER,
                "category_id": "cat-food",
                "month": "2026-10",
                "status": "dismissed",
                "suggested_limit": 240,
            },
            {
                "id": "s2",
                "user_id": USER,
                "category_id": "cat-shop",
                "month": "2026-10",
                "status": "pending",
                "suggested_limit": 80,
            },
        ]
        suggestion = {
            "budget_id": "b-food",
            "category_id": "cat-food",
            "category": "Food",
            "month": "2026-10",
            "current_limit": 300,
            "suggested_limit": 200,
            "basis": {},
        }
        user_model.write_suggestions(USER, "2026-10", [suggestion])
        rows = {r["id"]: r for r in self.db.tables["budget_suggestions"]}
        self.assertEqual(rows["s1"]["status"], "dismissed")
        self.assertEqual(rows["s1"]["suggested_limit"], 240)
        self.assertNotIn("s2", rows)  # stale pending suggestion withdrawn

    def test_stats_rows_that_disappear_are_deleted(self):
        user_model.write_category_month_stats(
            USER,
            [
                {"month": "2026-10", "category": "Food", "spent": 1, "tx_count": 1},
                {"month": "2026-10", "category": "Shopping", "spent": 1, "tx_count": 1},
            ],
        )
        user_model.write_category_month_stats(
            USER, [{"month": "2026-10", "category": "Food", "spent": 2, "tx_count": 2}]
        )
        rows = self.db.tables["category_month_stats"]
        self.assertEqual([(r["category"], r["spent"]) for r in rows], [("Food", 2)])

    def test_refresh_end_to_end(self):
        self.db.tables.update(
            {
                "transactions": [{**r, "user_id": USER} for r in HISTORY + OCTOBER],
                "category_match_rules": [],
                "budgets": [{**b, "user_id": USER, "month_year": "2026-10"} for b in BUDGETS],
                "categories": [
                    {"id": cid, "name": name, "user_id": None} for cid, name in CATEGORIES.items()
                ],
            }
        )
        result = user_model.refresh_user_model(USER, TODAY)
        self.assertEqual(len(result["tx_rows"]), len(HISTORY + OCTOBER))
        self.assertEqual(result["alerts"], 3)
        self.assertEqual(result["suggestions"], 1)
        self.assertEqual(
            self.db.tables["budget_suggestions"][0]["status"],
            "pending",
        )
        self.assertTrue(self.db.tables["category_month_stats"])

    def test_missing_tables_never_raise(self):
        broken = mock.MagicMock()
        broken.table.side_effect = RuntimeError('relation "budget_alerts" does not exist')
        with mock.patch.object(user_model, "supabase", broken):
            result = user_model.refresh_user_model(USER, TODAY)
        self.assertEqual(result["tx_rows"], [])


if __name__ == "__main__":
    unittest.main()
