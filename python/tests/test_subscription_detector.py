import datetime as dt
import unittest

from subscription_detector import _detect_from_rows, _next_charge_date


class NextChargeDateTests(unittest.TestCase):
    def test_monthly_keeps_the_day_of_the_month(self):
        self.assertEqual(_next_charge_date(dt.date(2026, 10, 18), "monthly"), dt.date(2026, 11, 18))
        self.assertEqual(_next_charge_date(dt.date(2026, 10, 2), "monthly"), dt.date(2026, 11, 2))

    def test_monthly_clamps_to_the_last_day(self):
        self.assertEqual(_next_charge_date(dt.date(2027, 1, 31), "monthly"), dt.date(2027, 2, 28))
        self.assertEqual(_next_charge_date(dt.date(2026, 12, 15), "monthly"), dt.date(2027, 1, 15))

    def test_weekly_and_annual(self):
        self.assertEqual(_next_charge_date(dt.date(2026, 10, 18), "weekly"), dt.date(2026, 10, 25))
        self.assertEqual(_next_charge_date(dt.date(2026, 10, 18), "annual"), dt.date(2027, 10, 18))

    def test_detected_subscription_renews_on_the_same_day(self):
        rows = [
            {"merchant_name": "Spotify", "date": d, "amount": 21.99, "plaid_account_id": "card"}
            for d in ("2026-08-18", "2026-09-18", "2026-10-18")
        ]
        (sub,) = _detect_from_rows(rows, today=dt.date(2026, 10, 21))
        self.assertEqual(sub["next_charge_date"], "2026-11-18")


if __name__ == "__main__":
    unittest.main()
