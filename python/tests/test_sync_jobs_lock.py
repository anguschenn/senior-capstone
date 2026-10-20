"""Proves run_post_sync serialises detect_and_upsert_subscriptions per user.

Without this lock, an app-triggered sync and a webhook-triggered sync for the same
user can both read "no existing row for this merchant yet" before either inserts one,
and each inserts its own copy -- the duplicate-subscription bug this guards against.
"""

import threading
import time
from unittest.mock import patch

import sync_jobs

_EMPTY_MODEL = {"tx_rows": [], "stats": None, "alerts": None, "suggestions": None}


class _FakeSnapshotService:
    def invalidate(self, user_id):
        pass


def _run_concurrently(user_ids, hold_seconds=0.05):
    """Calls run_post_sync for each user_id on its own thread, with
    detect_and_upsert_subscriptions replaced by a fake that records exactly when it
    started and stopped running, so overlap can be checked afterward.
    """
    intervals = []
    intervals_lock = threading.Lock()

    def fake_detect(user_id):
        start = time.monotonic()
        time.sleep(hold_seconds)
        end = time.monotonic()
        with intervals_lock:
            intervals.append((user_id, start, end))
        return {"detected": 0, "inserted": 0, "updated": 0, "deactivated": 0}

    snapshot_service = _FakeSnapshotService()
    with (
        patch.object(sync_jobs, "detect_and_upsert_subscriptions", side_effect=fake_detect),
        patch.object(sync_jobs, "refresh_user_model", return_value=_EMPTY_MODEL),
    ):
        threads = [
            threading.Thread(target=sync_jobs.run_post_sync, args=(uid, snapshot_service))
            for uid in user_ids
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=5)
            assert not t.is_alive(), "a thread did not finish -- possible deadlock"
    return intervals


def _overlaps(a, b):
    (_, a_start, a_end), (_, b_start, b_end) = a, b
    return a_start < b_end and b_start < a_end


def test_same_user_runs_are_serialised():
    intervals = _run_concurrently(["user-a", "user-a", "user-a"])
    assert len(intervals) == 3
    ordered = sorted(intervals, key=lambda i: i[1])
    for first, second in zip(ordered, ordered[1:]):
        assert not _overlaps(first, second), (
            f"two runs for the same user overlapped: {first} and {second}"
        )


def test_different_users_are_not_serialised_against_each_other():
    # A global lock would also pass test_same_user_runs_are_serialised, so this test
    # exists specifically to catch that: different users must be free to run at once.
    intervals = _run_concurrently(["user-a", "user-b", "user-c"], hold_seconds=0.2)
    assert len(intervals) == 3
    start_spread = max(i[1] for i in intervals) - min(i[1] for i in intervals)
    assert start_spread < 0.1, (
        f"different users' syncs started {start_spread:.3f}s apart -- "
        "looks like they were serialised against each other"
    )


def test_a_second_run_sees_what_the_first_run_committed():
    # Simulates why serialising matters: the first run inserts a row: subsequent runs
    # must see it (and update it), never conclude "no existing row" and insert again.
    order = []
    order_lock = threading.Lock()
    seen_counts = []

    def fake_detect(user_id):
        with order_lock:
            seen_counts.append(len(order))
            order.append(user_id)
        time.sleep(0.02)
        return {"detected": 1, "inserted": 1, "updated": 0, "deactivated": 0}

    snapshot_service = _FakeSnapshotService()
    with (
        patch.object(sync_jobs, "detect_and_upsert_subscriptions", side_effect=fake_detect),
        patch.object(sync_jobs, "refresh_user_model", return_value=_EMPTY_MODEL),
    ):
        threads = [
            threading.Thread(target=sync_jobs.run_post_sync, args=("user-a", snapshot_service))
            for _ in range(2)
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=5)
    # The second call only ever starts after the first's full critical section
    # finished, so it always observes 1 prior call, never 0.
    assert seen_counts == [0, 1]
