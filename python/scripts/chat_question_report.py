"""List chat questions that weren't fully answered, most common wording first.

usage: python scripts/chat_question_report.py [--days 14] [--all] [--db | --file PATH]

--db reads the chat_question_log table (migration 014; what the deployed app writes);
otherwise it reads the local question log file written by ai/question_log.py. By default it shows only the
questions worth fixing: unclear, partial, error, and the ones the rules didn't recognize
and the model had to restate ("rewritten"). --all includes answered ones.
"""

import argparse
import collections
import datetime as dt
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from ai.question_log import LOG_PATH  # noqa: E402

WORTH_FIXING = {"unclear", "partial", "error", "rewritten"}


def _read_file(path, since):
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("asked_at", "") >= since:
                yield row


def _read_table(since, page_size=1000):
    from supabase_repo import supabase

    start = 0
    while True:
        page = (
            supabase.table("chat_question_log")
            .select("asked_at,question,intent,answer_source,outcome,missing")
            .gte("asked_at", since)
            .order("asked_at", desc=True)
            .range(start, start + page_size - 1)
            .execute()
        ).data or []
        yield from page
        if len(page) < page_size:
            return
        start += page_size


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=14)
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--file", default=LOG_PATH)
    parser.add_argument("--db", action="store_true", help="read the chat_question_log table")
    args = parser.parse_args()
    since = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=args.days)).isoformat()
    if args.db:
        source = _read_table(since)
    else:
        if not os.path.exists(args.file):
            print(f"No question log at {args.file} yet.")
            return
        source = _read_file(args.file, since)
    rows = [r for r in source if args.all or r.get("outcome") in WORTH_FIXING]
    counts = collections.Counter(
        (r["outcome"], r["question"].strip().lower(), r.get("missing") or "") for r in rows
    )
    print(
        f"{len(rows)} questions in the last {args.days} days: "
        f"{dict(collections.Counter(r['outcome'] for r in rows))}"
    )
    for (outcome, question, missing), n in counts.most_common():
        extra = f"  (left out: {missing})" if missing else ""
        print(f"{n:4d}  {outcome:<9} {question}{extra}")


if __name__ == "__main__":
    main()
