"""Hourly scheduler entry point; sends once at 9 AM America/New_York on day one."""

import datetime as dt
import logging
from zoneinfo import ZoneInfo

from push_notifications import dispatch_pending_notifications, push_enabled
from supabase_repo import supabase

EASTERN = ZoneInfo("America/New_York")


def previous_month_key(now: dt.datetime) -> str:
    local = now.astimezone(EASTERN)
    year, month = local.year, local.month - 1
    if month == 0:
        year, month = year - 1, 12
    return f"{year:04d}-{month:02d}"


def is_monthly_report_time(now: dt.datetime) -> bool:
    local = now.astimezone(EASTERN)
    return local.day == 1 and local.hour == 9


def run(now: dt.datetime | None = None) -> int:
    if not push_enabled():
        logging.warning("Browser push is not configured; monthly reports were not sent.")
        return 0

    now = now or dt.datetime.now(dt.timezone.utc)
    users = (supabase.table("push_subscriptions").select("user_id").execute()).data or []
    user_ids = sorted({str(row["user_id"]) for row in users if row.get("user_id")})

    if is_monthly_report_time(now):
        month = previous_month_key(now)
        for user_id in user_ids:
            supabase.table("notification_deliveries").upsert(
                {
                    "user_id": user_id,
                    "event_key": f"monthly-report:{month}",
                    "kind": "monthly_report",
                    "title": "Your SmartSpend monthly report is ready",
                    "body": "Open SmartSpend to review last month's spending.",
                    "url": f"/?notification=monthly_report&month={month}",
                    "status": "pending",
                },
                on_conflict="user_id,event_key",
                ignore_duplicates=True,
            ).execute()

    for user_id in user_ids:
        dispatch_pending_notifications(user_id)
    logging.info("Processed monthly reports and pending pushes for %d user(s).", len(user_ids))
    return len(user_ids)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    run()
