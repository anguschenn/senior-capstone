import datetime as dt
import unittest
from unittest import mock

import sync_jobs


class RecordSyncTests(unittest.TestCase):
    def test_upserts_one_row_per_user_with_utc_time(self):
        fake = mock.MagicMock()
        with mock.patch.object(sync_jobs, "supabase", fake):
            sync_jobs.record_sync("user-1", "webhook")

        fake.table.assert_called_once_with("sync_status")
        (payload,) = fake.table.return_value.upsert.call_args.args
        self.assertEqual(payload["user_id"], "user-1")
        self.assertEqual(payload["source"], "webhook")
        self.assertEqual(
            fake.table.return_value.upsert.call_args.kwargs, {"on_conflict": "user_id"}
        )
        stamped = dt.datetime.fromisoformat(payload["last_synced_at"])
        self.assertEqual(stamped.utcoffset(), dt.timedelta(0))
        self.assertLess(abs(dt.datetime.now(dt.timezone.utc) - stamped), dt.timedelta(seconds=5))

    def test_missing_table_never_breaks_a_sync(self):
        fake = mock.MagicMock()
        fake.table.return_value.upsert.return_value.execute.side_effect = RuntimeError(
            'relation "sync_status" does not exist'
        )
        with mock.patch.object(sync_jobs, "supabase", fake):
            sync_jobs.record_sync("user-1", "app")  # must not raise


if __name__ == "__main__":
    unittest.main()
