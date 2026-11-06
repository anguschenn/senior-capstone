import base64
import contextlib
import datetime as dt
import io
import unittest
from unittest import mock

from cryptography.hazmat.primitives import serialization
from py_vapid import Vapid

import push_notifications
from budget_progress import rule_key_for_row
from scripts.generate_vapid_keys import main as generate_vapid_keys
from scripts.send_monthly_reports import is_monthly_report_time, previous_month_key


def _b64url(size):
    return base64.urlsafe_b64encode(bytes(range(size))).decode("ascii").rstrip("=")


class PushSubscriptionValidationTests(unittest.TestCase):
    def setUp(self):
        self.subscription = {
            "endpoint": "https://fcm.googleapis.com/fcm/send/test-token",
            "keys": {"p256dh": _b64url(65), "auth": _b64url(16)},
        }

    def test_accepts_a_chrome_subscription(self):
        self.assertEqual(
            push_notifications.validate_push_subscription(self.subscription),
            {
                "endpoint": self.subscription["endpoint"],
                "p256dh": self.subscription["keys"]["p256dh"],
                "auth": self.subscription["keys"]["auth"],
            },
        )

    def test_rejects_non_chrome_endpoint(self):
        self.subscription["endpoint"] = "https://example.com/fcm/send/token"
        with self.assertRaisesRegex(ValueError, "Only Chrome"):
            push_notifications.validate_push_subscription(self.subscription)

    def test_rejects_invalid_encryption_keys(self):
        self.subscription["keys"]["auth"] = _b64url(15)
        with self.assertRaisesRegex(ValueError, "authentication key"):
            push_notifications.validate_push_subscription(self.subscription)


class VapidKeyGenerationTests(unittest.TestCase):
    def test_generated_private_key_matches_published_key_format(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            generate_vapid_keys()
        values = dict(line.split("=", 1) for line in output.getvalue().splitlines())
        vapid = Vapid.from_string(values["PUSH_VAPID_PRIVATE_KEY"])
        public_bytes = vapid.public_key.public_bytes(
            serialization.Encoding.X962,
            serialization.PublicFormat.UncompressedPoint,
        )
        self.assertEqual(
            values["PUSH_VAPID_PUBLIC_KEY"],
            base64.urlsafe_b64encode(public_bytes).decode("ascii").rstrip("="),
        )
        self.assertEqual(len(values["PUSH_VAPID_PRIVATE_KEY"]), 43)


class TransactionReviewNotificationTests(unittest.TestCase):
    def test_only_notifies_unresolved_low_confidence_transactions(self):
        low_confidence = {
            "plaid_transaction_id": "tx-low",
            "amount": 12,
            "name": "Local Market",
            "pfc_primary": "FOOD_AND_DRINK",
            "pfc_detailed": "",
        }
        medium_confidence = {
            "plaid_transaction_id": "tx-medium",
            "amount": 12,
            "name": "Merchant",
            "pfc_primary": "FOOD_AND_DRINK",
            "pfc_detailed": "FOOD_AND_DRINK_RESTAURANT",
        }
        remembered = {
            "plaid_transaction_id": "tx-remembered",
            "amount": 12,
            "name": "Remembered",
            "pfc_primary": "FOOD_AND_DRINK",
            "pfc_detailed": "",
        }
        decision = {
            "plaid_transaction_id": "tx-decided",
            "amount": 12,
            "name": "Decided",
            "pfc_primary": "FOOD_AND_DRINK",
            "pfc_detailed": "",
        }
        rows = [low_confidence, medium_confidence, remembered, decision]
        rules = {rule_key_for_row(remembered): "Food"}
        decisions = {"tx-decided": {"category": "Food"}}

        with (
            mock.patch.object(push_notifications, "fetch_all_transactions", return_value=rows),
            mock.patch.object(push_notifications, "fetch_rules", return_value=rules),
            mock.patch.object(push_notifications, "fetch_decisions", return_value=decisions),
        ):
            events = push_notifications.pending_transaction_review_events("user-1")

        self.assertEqual([event["event_key"] for event in events], ["transaction-review:tx-low"])
        self.assertEqual(events[0]["url"], "/?notification=transaction_review")


class PendingBudgetNotificationTests(unittest.TestCase):
    def test_existing_unresolved_alerts_are_candidates_when_notifications_are_enabled(self):
        query = mock.MagicMock()
        query.select.return_value = query
        query.eq.return_value = query
        query.is_.return_value = query
        query.limit.return_value = query
        query.execute.return_value.data = [
            {
                "month": "2026-10",
                "category_id": "food",
                "kind": "over_budget",
                "first_detected_at": "2026-10-10T12:00:00+00:00",
            }
        ]
        with mock.patch.object(push_notifications, "supabase") as database:
            database.table.return_value = query
            events = push_notifications._pending_budget_events("user-1")

        self.assertEqual(
            events[0]["event_key"],
            "budget:2026-10:food:over_budget:2026-10-10T12:00:00+00:00",
        )
        self.assertEqual(events[0]["kind"], "budget_alert")
        query.is_.assert_any_call("resolved_at", "null")
        query.is_.assert_any_call("notified_at", "null")

    def test_duplicate_budget_events_are_queued_once(self):
        event = {
            "event_key": "budget:2026-10:food:over_budget:detected",
            "kind": "budget_alert",
            "url": "/?notification=budget",
        }
        with (
            mock.patch.object(push_notifications, "push_enabled", return_value=True),
            mock.patch.object(push_notifications, "_pending_budget_events", return_value=[event]),
            mock.patch.object(push_notifications, "_pending_subscription_events", return_value=[]),
            mock.patch.object(
                push_notifications, "pending_transaction_review_events", return_value=[]
            ),
            mock.patch.object(push_notifications, "_queue_event") as queue_event,
            mock.patch.object(push_notifications, "dispatch_pending_notifications"),
        ):
            push_notifications.process_user_notifications("user-1", [event])

        queue_event.assert_called_once()

    def test_successful_budget_delivery_can_mark_its_alert_notified(self):
        query = mock.MagicMock()
        query.update.return_value = query
        query.eq.return_value = query
        query.is_.return_value = query
        with mock.patch.object(push_notifications, "supabase") as database:
            database.table.return_value = query
            push_notifications._mark_budget_alert_notified(
                "user-1",
                "budget:2026-10:food:over_budget:2026-10-10T12:00:00+00:00",
            )

        query.eq.assert_any_call("month", "2026-10")
        query.eq.assert_any_call("category_id", "food")
        query.eq.assert_any_call("kind", "over_budget")
        query.eq.assert_any_call("first_detected_at", "2026-10-10T12:00:00+00:00")


class MonthlyReportScheduleTests(unittest.TestCase):
    def test_sends_at_nine_am_eastern_during_standard_time(self):
        now = dt.datetime(2026, 11, 1, 14, 0, tzinfo=dt.timezone.utc)
        self.assertTrue(is_monthly_report_time(now))

    def test_sends_at_nine_am_eastern_during_daylight_time(self):
        now = dt.datetime(2026, 7, 1, 13, 0, tzinfo=dt.timezone.utc)
        self.assertTrue(is_monthly_report_time(now))

    def test_does_not_send_at_other_times_or_days(self):
        self.assertFalse(
            is_monthly_report_time(dt.datetime(2026, 7, 1, 14, 0, tzinfo=dt.timezone.utc))
        )
        self.assertFalse(
            is_monthly_report_time(dt.datetime(2026, 7, 2, 13, 0, tzinfo=dt.timezone.utc))
        )

    def test_previous_month_rolls_back_across_year_boundary(self):
        now = dt.datetime(2026, 1, 1, 14, 0, tzinfo=dt.timezone.utc)
        self.assertEqual(previous_month_key(now), "2025-12")


if __name__ == "__main__":
    unittest.main()
