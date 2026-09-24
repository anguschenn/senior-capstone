"""Unit tests for budget overrun / burn-rate pace projection."""

import unittest
from unittest.mock import patch

from ai.predict_service import PredictService


class BurnRateBudgetOverrunTests(unittest.TestCase):
    def setUp(self):
        self.service = PredictService(generate_reply=lambda *a, **k: "{}")

    @patch.object(
        PredictService,
        "_month_burn_rate_context",
        return_value=(10, 30),
    )
    def test_projects_over_budget_on_high_pace(self, _mock_ctx):
        # Spent $200 in 10 days on $300 limit → pace $20/day → EOM $600.
        progress = [
            {"category": "Dining", "spent": 200, "limit": 300, "ratio": 200 / 300},
        ]
        forecast, _why, alerts, _actions, _signal, sufficient = self.service._budget_overrun(
            "month", progress
        )
        self.assertTrue(sufficient)
        self.assertEqual(forecast["at_risk_count"], 1)
        self.assertGreater(forecast["estimated_projected_overrun_total"], 0)
        self.assertTrue(alerts)
        self.assertEqual(alerts[0]["level"], "high")
        self.assertIn("burn rate", alerts[0]["message"].lower())

    @patch.object(
        PredictService,
        "_month_burn_rate_context",
        return_value=(10, 30),
    )
    def test_low_pace_no_false_alarm(self, _mock_ctx):
        # Spent $50 in 10 days on $300 limit → EOM $150, under budget.
        progress = [
            {"category": "Dining", "spent": 50, "limit": 300, "ratio": 50 / 300},
        ]
        forecast, _why, alerts, _actions, _signal, sufficient = self.service._budget_overrun(
            "month", progress
        )
        self.assertTrue(sufficient)
        self.assertEqual(forecast["at_risk_count"], 0)
        self.assertEqual(alerts, [])

    @patch.object(
        PredictService,
        "_month_burn_rate_context",
        return_value=(10, 30),
    )
    def test_approaching_pace_med_alert(self, _mock_ctx):
        # Spent $90 in 10 days on $300 → EOM $270 (90% of limit) → med.
        progress = [
            {"category": "Groceries", "spent": 90, "limit": 300, "ratio": 90 / 300},
        ]
        forecast, _why, alerts, _actions, _signal, _suf = self.service._budget_overrun(
            "month", progress
        )
        self.assertEqual(forecast["at_risk_count"], 1)
        self.assertEqual(alerts[0]["level"], "med")
        self.assertIn("near limit", alerts[0]["message"].lower())

    def test_year_view_skips_burn_rate_uses_ratio(self):
        progress = [
            {"category": "Travel", "spent": 900, "limit": 1000, "ratio": 0.9},
        ]
        forecast, _why, alerts, _actions, _signal, _suf = self.service._budget_overrun(
            "year", progress
        )
        self.assertFalse(forecast.get("burn_rate_enabled"))
        self.assertEqual(forecast["at_risk_count"], 1)
        self.assertIn("90%", alerts[0]["message"])


if __name__ == "__main__":
    unittest.main()
