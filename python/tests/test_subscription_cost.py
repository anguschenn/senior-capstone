"""Subscription cost projection in the forecast."""

import unittest

from ai.predict_service import PredictService


class SubscriptionCostTests(unittest.TestCase):
    def setUp(self):
        self.service = PredictService(generate_reply=lambda *a, **k: "{}")

    def _monthly(self, frequency, amount):
        forecast = self.service._subscription_cost(
            {}, [{"name": "Sub", "amount": amount, "frequency": frequency}]
        )[0]
        return forecast["projected_monthly_subscription_cost"]

    def test_annual_charge_is_spread_over_twelve_months(self):
        # subscription_detector emits "annual" for yearly charges.
        self.assertEqual(self._monthly("annual", 120), 10.0)

    def test_yearly_and_monthly_still_work(self):
        self.assertEqual(self._monthly("yearly", 120), 10.0)
        self.assertEqual(self._monthly("monthly", 15), 15.0)


if __name__ == "__main__":
    unittest.main()
