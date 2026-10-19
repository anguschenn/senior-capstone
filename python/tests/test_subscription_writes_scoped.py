"""Subscription writes must filter by user_id (service-role key, RLS bypassed)."""

import unittest
from collections import defaultdict
from types import SimpleNamespace
from unittest import mock

import subscription_detector as sd


def _fake_db():
    tables = defaultdict(mock.MagicMock)
    fake_db = mock.MagicMock()
    fake_db.table.side_effect = lambda name: tables[name]
    return fake_db, tables


def _update_filters(table):
    first = table.update.return_value.eq
    second = first.return_value.eq
    return {first.call_args.args, second.call_args.args if second.call_args else None}


class SubscriptionWriteScopeTests(unittest.TestCase):
    def test_stale_deactivation_is_scoped_to_the_user(self):
        fake_db, tables = _fake_db()
        active = tables["subscriptions"].select.return_value.eq.return_value.eq.return_value
        active.eq.return_value.execute.return_value = SimpleNamespace(
            data=[
                {
                    "id": "sub-1",
                    "merchant_name": "Netflix",
                    "frequency": "monthly",
                    "next_charge_date": "2020-01-01",
                }
            ]
        )
        with mock.patch.object(sd, "supabase", fake_db):
            deactivated = sd._mark_stale_subscriptions("user-1", [])

        self.assertEqual(deactivated, 1)
        tables["subscriptions"].update.assert_called_once_with({"is_active": False})
        self.assertEqual(
            _update_filters(tables["subscriptions"]), {("id", "sub-1"), ("user_id", "user-1")}
        )

    def test_redetected_subscription_update_is_scoped_to_the_user(self):
        fake_db, tables = _fake_db()
        tables[
            "transactions"
        ].select.return_value.eq.return_value.eq.return_value.gt.return_value.order.return_value.limit.return_value.execute.return_value = SimpleNamespace(  # noqa: E501
            data=[]
        )
        tables[
            "subscriptions"
        ].select.return_value.eq.return_value.execute.return_value = SimpleNamespace(
            data=[{"id": "sub-1", "merchant_name": "Netflix"}]
        )
        candidate = {
            "norm_merchant": sd._normalize_merchant("Netflix"),
            "merchant_name": "Netflix",
            "account_id": "acc-1",
            "amount": 15.49,
            "frequency": "monthly",
            "next_charge_date": "2026-11-01",
            "needs_confirmation": False,
        }
        with (
            mock.patch.object(sd, "supabase", fake_db),
            mock.patch.object(sd, "_detect_from_rows", return_value=[candidate]),
            mock.patch.object(sd, "_mark_stale_subscriptions", return_value=0),
        ):
            result = sd.detect_and_upsert_subscriptions("user-1")

        self.assertEqual(result["updated"], 1)
        self.assertEqual(
            _update_filters(tables["subscriptions"]), {("id", "sub-1"), ("user_id", "user-1")}
        )


if __name__ == "__main__":
    unittest.main()
