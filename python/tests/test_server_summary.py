"""Server-built chat summary (ai/server_summary.py).

tests/data/ai_summary_contract.json is shared with
ssdemo_1/test/services/ai_summary_contract_test.dart: both build the summary from the same
rows and must produce the same `expected`. That is what keeps the chat's server numbers equal
to what AiSummaryService computes in the app.

After a deliberate rule change on both sides, regenerate `expected` from the Python side:
    python tests/test_server_summary.py --write
then make the Dart test pass.
"""

import datetime as dt
import json
import math
import sys
import unittest
from pathlib import Path
from unittest import mock

from ai import server_summary

FIXTURE_PATH = Path(__file__).parent / "data" / "ai_summary_contract.json"
# Not comparable across languages: the clock string and the zone name.
VOLATILE = {"generated_at"}


def _build(fixture, case):
    meta = {a["plaid_account_id"]: a for a in fixture["accounts"]}
    txs = server_summary.build_transactions(
        fixture["transactions"], meta, fixture["rules"], case["account_ids"] or None
    )
    summary = server_summary.build_summary(
        txs,
        case["budget_progress"],
        now=dt.datetime.fromisoformat(fixture["now"]),
        focus_month=case["focus_month"],
        all_year=case["all_year"],
        all_accounts=not case["account_ids"],
        scope_label=case["scope_label"],
        account_type=case["account_type"],
        tz_name="",
    )
    return {k: v for k, v in summary.items() if k not in VOLATILE}


def assert_close(test, actual, expected, path="$"):
    if isinstance(expected, dict):
        test.assertIsInstance(actual, dict, path)
        test.assertEqual(sorted(actual), sorted(expected), path)
        for key in expected:
            assert_close(test, actual[key], expected[key], f"{path}.{key}")
    elif isinstance(expected, list):
        test.assertIsInstance(actual, list, path)
        test.assertEqual(len(actual), len(expected), path)
        for i, (a, e) in enumerate(zip(actual, expected)):
            assert_close(test, a, e, f"{path}[{i}]")
    elif isinstance(expected, (int, float)) and not isinstance(expected, bool):
        test.assertTrue(
            isinstance(actual, (int, float)) and math.isclose(actual, expected, abs_tol=1e-6),
            f"{path}: {actual!r} != {expected!r}",
        )
    else:
        test.assertEqual(actual, expected, path)


class SummaryContractTests(unittest.TestCase):
    def test_cases_match_the_shared_fixture(self):
        fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        for case in fixture["cases"]:
            with self.subTest(case["description"]):
                assert_close(self, _build(fixture, case), case["expected"])

    def test_fixture_covers_the_tricky_rows(self):
        fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        october = next(c for c in fixture["cases"] if c["focus_month"] == "2026-10")["expected"]
        month = october["month_index"]["2026-10"]
        # The checking-side card payment is not spending; the card side is not income.
        self.assertEqual(month["card_payments_out"], 500)
        self.assertEqual(month["card_payments_in"], 500)
        # Payroll only: the Amazon refund lowers Shopping instead of counting as income.
        self.assertEqual(month["income"], 2000)
        self.assertEqual(month["categories"]["Shopping"], 90.0)
        # The remembered rule moves Starbucks out of Food.
        self.assertIn("Entertainment", month["categories"])
        # The duplicated Plaid id is counted once.
        self.assertEqual(october["data_coverage"]["transaction_count_total"], 22)


class ContextTests(unittest.TestCase):
    def test_parse_context(self):
        parsed = server_summary.parse_context(
            {
                "account_ids": ["b", "a", "a", ""],
                "selected_month": "2026-09",
                "today": "2026-10-10",
                "scope_label": "Card",
                "tz": "PDT",
            }
        )
        self.assertEqual(parsed["account_ids"], ["a", "b"])
        self.assertEqual(parsed["month"], "2026-09")
        self.assertFalse(parsed["all_year"])
        self.assertEqual(parsed["today"], dt.date(2026, 10, 10))

    def test_all_year_and_bad_values(self):
        parsed = server_summary.parse_context({"selected_month": "2026", "today": "nope"})
        self.assertTrue(parsed["all_year"])
        self.assertEqual(parsed["month"], "2026-01")
        self.assertEqual(parsed["today"], dt.date.today())
        self.assertIsNone(server_summary.parse_context("2026-10"))

    def test_summary_is_cached_until_invalidated(self):
        fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        loads = []

        def fake_load(user_id, tx_rows=None):
            loads.append(user_id)
            meta = {a["plaid_account_id"]: a for a in fixture["accounts"]}
            return fixture["transactions"], meta, fixture["rules"], {}

        context = server_summary.parse_context({"selected_month": "2026-10", "today": "2026-10-10"})
        with (
            mock.patch.object(server_summary, "_load", side_effect=fake_load),
            mock.patch("user_model.fetch_budget_rows", return_value=[]),
            mock.patch.object(server_summary, "fetch_alert_history", return_value=[]),
        ):
            first = server_summary.summary_for("cache-user", context)
            second = server_summary.summary_for("cache-user", context)
            server_summary.invalidate("cache-user")
            server_summary.summary_for("cache-user", context)
        self.assertIs(first, second)
        self.assertEqual(loads, ["cache-user", "cache-user"])
        self.assertEqual(first["month_index"]["2026-10"]["card_payments_out"], 500)


class AlertHistoryTests(unittest.TestCase):
    def test_reads_recent_unresolved_alerts_newest_first(self):
        from fake_supabase import FakeSupabase

        def alert(month, category, kind="over_budget", resolved=None):
            return {
                "user_id": "u1",
                "month": month,
                "category": category,
                "kind": kind,
                "spent": 120,
                "limit_amount": 100,
                "resolved_at": resolved,
            }

        db = FakeSupabase(
            {
                "budget_alerts": [
                    alert("2026-03", "Food"),  # older than 6 months
                    alert("2026-08", "Food"),
                    alert("2026-09", "Shopping"),
                    alert("2026-09", "Transport", resolved="2026-09-20"),
                    alert("2026-10", "Food", kind="projected_over"),
                    {**alert("2026-09", "Food"), "user_id": "someone-else"},
                ]
            }
        )
        with mock.patch("supabase_repo.supabase", db):
            history = server_summary.fetch_alert_history("u1", "2026-10")
        self.assertEqual(
            [(h["month"], h["category"], h["kind"]) for h in history],
            [
                ("2026-10", "Food", "projected_over"),
                ("2026-09", "Shopping", "over_budget"),
                ("2026-08", "Food", "over_budget"),
            ],
        )

    def test_prompt_context_names_the_overruns(self):
        from ai.chat_service import ChatService
        from ai.validators import sanitize_spending_summary

        summary = sanitize_spending_summary(
            {
                "totals": {"expenses_30d": 500},
                "alert_history": [
                    {
                        "month": "2026-09",
                        "category": "Food",
                        "kind": "over_budget",
                        "spent": 1349,
                        "limit": 810,
                    },
                    {
                        "month": "2026-10",
                        "category": "Food",
                        "kind": "approaching",
                        "spent": 10,
                        "limit": 20,
                    },
                ],
            }
        )
        text = ChatService(lambda *a, **k: "", lambda _u: "")._summary_to_text(summary)
        self.assertIn("months that ended over budget: 2026-09 Food $1349 of $810 limit", text)
        self.assertNotIn("approaching", text)


def _write_expected():
    fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
    for case in fixture["cases"]:
        case["expected"] = _build(fixture, case)
    FIXTURE_PATH.write_text(json.dumps(fixture, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {FIXTURE_PATH}")


if __name__ == "__main__":
    if "--write" in sys.argv:
        _write_expected()
    else:
        unittest.main()
