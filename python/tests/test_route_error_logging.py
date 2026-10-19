"""log_route_error keeps logs useful for debugging without dumping whole exceptions."""

import contextlib
import io
import unittest

from api.http_helpers import log_route_error

TAIL_SECRET = "Authorization: Bearer sk-live-abc123"


def _log(error):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        log_route_error("/api/test", error)
    return out.getvalue()


class RouteErrorLoggingTests(unittest.TestCase):
    def test_short_message_is_kept_for_debugging(self):
        line = _log(ValueError("bad month value"))
        self.assertEqual(line, "/api/test error: ValueError: bad month value\n")

    def test_long_message_is_truncated_to_200_chars(self):
        # e.g. a Plaid ApiException dumps headers and the full response body.
        error = RuntimeError("x" * 300 + TAIL_SECRET)
        line = _log(error)
        self.assertIn("RuntimeError", line)
        self.assertNotIn(TAIL_SECRET, line)
        self.assertNotIn("sk-live", line)
        message = line.split("RuntimeError: ", 1)[1].rstrip("\n")
        self.assertLessEqual(len(message), 200 + len("..."))
        self.assertTrue(message.endswith("..."))

    def test_multiline_message_stays_on_one_log_line(self):
        line = _log(RuntimeError("HTTP response headers:\nX-Request-Id: 1\nbody: {}"))
        self.assertEqual(line.count("\n"), 1)


if __name__ == "__main__":
    unittest.main()
