import datetime as dt
import json
import unittest
from pathlib import Path
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


def _stats():
    return user_model.build_category_month_stats(HISTORY + OCTOBER, {})


def _alerts():
    from budget_progress import build_budget_progress

    progress = build_budget_progress(BUDGETS, CATEGORIES, HISTORY + OCTOBER, {}, "2026-10")
    return user_model.build_alerts(progress, TODAY)


class AutoLimitContractTests(unittest.TestCase):
    """Shared with ssdemo_1/test/services/budget_auto_limit_contract_test.dart."""

    def test_cases(self):
        fixture = json.loads(
            (Path(__file__).parent / "data" / "budget_auto_limit_contract.json").read_text()
        )
        for case in fixture["cases"]:
            with self.subTest(case["description"]):
                self.assertEqual(
                    user_model.auto_limits(
                        case["stats"], case["cards"], case["previous"], case["month"]
                    ),
                    case["expected"],
                )


class SuggestionTests(unittest.TestCase):
    def test_trimmed_mean_drops_high_and_low(self):
        self.assertEqual(user_model.trimmed_mean([200, 250, 260, 240, 900, 100]), 237.5)
        self.assertEqual(user_model.trimmed_mean([10, 20]), 15)

    def test_only_alerted_cards_below_their_normal_are_raised(self):
        # Food is alerted and 300 > its normal 240: no raise. Shopping is alerted (over)
        # with a 100 limit and normal 100: nothing. Lower Food's limit to 150: raise to 240.
        budgets = [dict(b) for b in BUDGETS]
        self.assertEqual(
            user_model.build_suggestions(budgets, CATEGORIES, _stats(), "2026-10", _alerts()), []
        )
        budgets[0]["monthly_limit"] = 150
        (suggestion,) = user_model.build_suggestions(
            budgets, CATEGORIES, _stats(), "2026-10", _alerts()
        )
        self.assertEqual(suggestion["category"], "Food")
        self.assertEqual(suggestion["suggested_limit"], 240.0)
        self.assertEqual(suggestion["current_limit"], 150.0)

    def test_no_alert_no_suggestion(self):
        budgets = [{"id": "b-food", "category_id": "cat-food", "monthly_limit": 50}]
        self.assertEqual(
            user_model.build_suggestions(budgets, CATEGORIES, _stats(), "2026-10", []), []
        )

    def test_months_over_counts_history_months_over_their_limit(self):
        budgets = [{"id": "b-food", "category_id": "cat-food", "monthly_limit": 150}]
        alerts = [{"category_id": "cat-food"}]
        past = {"2026-08": {"food": 800}, "2026-09": {"food": 90}, "2026-07": {"food": 0}}
        (suggestion,) = user_model.build_suggestions(
            budgets, CATEGORIES, _stats(), "2026-10", alerts, past
        )
        # August 900 > 800 and September 100 > 90; July has no limit.
        self.assertEqual(suggestion["basis"]["months_over"], 2)

    def test_needs_three_months_of_history(self):
        rows = [food("2026-08-05", 100), food("2026-09-05", 100)]
        stats = user_model.build_category_month_stats(rows, {})
        alerts = [{"category_id": "cat-food"}]
        self.assertEqual(
            user_model.build_suggestions(BUDGETS, CATEGORIES, stats, "2026-10", alerts), []
        )


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
        self.assertEqual(result["suggestions"], 0)  # every alerted limit is at or above normal
        self.assertTrue(self.db.tables["category_month_stats"])

    def _seed_previous_month(self, source="auto"):
        self.db.tables.update(
            {
                "budgets": [
                    {**b, "user_id": USER, "month_year": "2026-09", "limit_source": source}
                    for b in BUDGETS
                ],
            }
        )

    def test_new_month_rows_come_from_history(self):
        self._seed_previous_month()
        rows = user_model.ensure_month_budget_rows(USER, "2026-10", _stats(), CATEGORIES)
        by_category = {r["category_id"]: r for r in rows}
        self.assertEqual(by_category["cat-food"]["monthly_limit"], 240.0)
        self.assertEqual(by_category["cat-shop"]["monthly_limit"], 100.0)
        self.assertEqual(by_category["cat-food"]["limit_source"], "auto")

    def test_user_limits_carry_forward(self):
        self._seed_previous_month(source="user")
        rows = user_model.ensure_month_budget_rows(USER, "2026-10", _stats(), CATEGORIES)
        food_row = next(r for r in rows if r["category_id"] == "cat-food")
        self.assertEqual((food_row["monthly_limit"], food_row["limit_source"]), (300, "user"))

    def test_existing_rows_are_never_touched(self):
        self._seed_previous_month()
        self.db.tables["budgets"].append(
            {
                "id": "b-oct",
                "user_id": USER,
                "category_id": "cat-food",
                "month_year": "2026-10",
                "monthly_limit": 77,
                "limit_source": "user",
            }
        )
        rows = user_model.ensure_month_budget_rows(USER, "2026-10", _stats(), CATEGORIES)
        self.assertEqual([(r["id"], r["monthly_limit"]) for r in rows], [("b-oct", 77)])

    def test_no_previous_month_leaves_it_to_the_app(self):
        self.assertEqual(user_model.ensure_month_budget_rows(USER, "2026-10", _stats(), {}), [])
        self.assertFalse(self.db.tables.get("budgets"))

    def test_finished_month_alerts_are_history(self):
        self._seed_previous_month()
        written = user_model.finalize_month_alerts(
            USER, "2026-09", HISTORY + OCTOBER, {}, CATEGORIES
        )
        self.assertEqual(written, 0)  # Food 100 and Shopping 100 vs 300 and 100: not over
        self.db.tables["budgets"][0]["monthly_limit"] = 90  # Food limit 90 < 100 spent
        self.assertEqual(
            user_model.finalize_month_alerts(USER, "2026-09", HISTORY + OCTOBER, {}, CATEGORIES), 1
        )
        (row,) = self.db.tables["budget_alerts"]
        self.assertEqual((row["kind"], row["month"]), ("over_budget", "2026-09"))
        self.assertIsNotNone(row["notified_at"])  # never reaches a future push sender

    def test_missing_tables_never_raise(self):
        broken = mock.MagicMock()
        broken.table.side_effect = RuntimeError('relation "budget_alerts" does not exist')
        with mock.patch.object(user_model, "supabase", broken):
            result = user_model.refresh_user_model(USER, TODAY)
        self.assertEqual(result["tx_rows"], [])


if __name__ == "__main__":
    unittest.main()
