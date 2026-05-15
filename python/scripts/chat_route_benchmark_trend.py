#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def _load_jsonl(path: Path):
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            continue
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Print trend summary from chat-route benchmark history JSONL."
    )
    parser.add_argument(
        "--history-jsonl",
        default=".artifacts/chat_route_benchmark_history.jsonl",
        help="Path to benchmark history jsonl.",
    )
    parser.add_argument("--tail", type=int, default=10, help="How many recent rows to inspect.")
    args = parser.parse_args()

    path = Path(args.history_jsonl)
    rows = _load_jsonl(path)
    if not rows:
        print(f"No benchmark history found at {path}")
        return

    tail_rows = rows[-max(1, args.tail) :]
    latest = tail_rows[-1]
    prev = tail_rows[-2] if len(tail_rows) > 1 else None

    print(f"history_file={path}")
    print(f"entries={len(rows)} showing_last={len(tail_rows)}")
    print(
        "latest "
        f"ts={latest.get('timestamp_utc', '')} "
        f"intent_accuracy={latest.get('intent_accuracy')} "
        f"answer_source_accuracy={latest.get('answer_source_accuracy')} "
        f"deterministic_rate={latest.get('deterministic_rate')} "
        f"clarification_rate={latest.get('clarification_rate')}"
    )
    if prev:

        def delta(key):
            a = float(latest.get(key, 0) or 0)
            b = float(prev.get(key, 0) or 0)
            return round(a - b, 3)

        print(
            "delta_vs_prev "
            f"intent_accuracy={delta('intent_accuracy'):+.3f} "
            f"answer_source_accuracy={delta('answer_source_accuracy'):+.3f} "
            f"deterministic_rate={delta('deterministic_rate'):+.3f} "
            f"clarification_rate={delta('clarification_rate'):+.3f}"
        )


if __name__ == "__main__":
    main()
