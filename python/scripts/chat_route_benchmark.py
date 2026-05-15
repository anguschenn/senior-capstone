#!/usr/bin/env python3
import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ai.chat_service import ChatService


def _service() -> ChatService:
    def generate_reply(_prompt: str, generation_config: dict[str, Any] | None = None) -> str:
        _ = generation_config
        return '{"reply":"model"}'

    return ChatService(generate_reply=generate_reply, get_detailed_snapshot=lambda _uid: "")


def _sample_summary() -> dict[str, Any]:
    return {
        "scope": "all_accounts",
        "scope_label": "Overall (All Accounts)",
        "time_anchor": {"selected_month": "2026-05", "selected_year": 2026},
        "month_index": {
            "2026-05": {
                "income": 2100.0,
                "expenses": 2020.0,
                "top_category": {"name": "Food", "amount": 160},
            },
            "2026-04": {
                "income": 1997.75,
                "expenses": 1987.86,
                "top_category": {"name": "Subscriptions", "amount": 131},
            },
            "2026-03": {
                "income": 1800.0,
                "expenses": 1750.0,
                "top_category": {"name": "Food", "amount": 120},
            },
        },
        "recent_transactions": [
            {"date": "2026-05-08", "name": "Netflix", "amount": -15.99},
            {"date": "2026-05-07", "name": "Uber", "amount": -12.5},
            {"date": "2026-05-06", "name": "Spotify", "amount": -10.99},
        ],
        "totals": {"tx_count_30d": 22, "income_30d": 3898, "expenses_30d": 3842},
        "year_index": {
            "2026": {"income": 9500.0, "expenses": 9100.0},
            "2025": {"income": 8700.0, "expenses": 8200.0},
        },
    }


DEFAULT_DATASET_PATH = (
    Path(__file__).resolve().parents[1] / "tests" / "data" / "chat_route_benchmark_en.json"
)


def _ask(svc: ChatService, prompt: str) -> dict[str, Any]:
    return svc.handle_chat(
        {"prompt": prompt, "history": [], "spending_summary": _sample_summary()},
        user_id="benchmark-user",
    )

def _load_dataset(path: str) -> list[dict[str, str]]:
    dataset_path = Path(path)
    rows = json.loads(dataset_path.read_text(encoding="utf-8"))
    if not isinstance(rows, list):
        raise ValueError(f"Dataset at {dataset_path} must be a JSON list")
    cleaned = []
    for idx, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ValueError(f"Dataset row #{idx} is not an object")
        prompt = str(row.get("prompt", "")).strip()
        intent = str(row.get("intent", "")).strip()
        source = str(row.get("source", "")).strip()
        if not prompt or not intent or not source:
            raise ValueError(f"Dataset row #{idx} missing prompt/intent/source")
        cleaned.append({"prompt": prompt, "intent": intent, "source": source})
    return cleaned


def main() -> None:
    parser = argparse.ArgumentParser(description="Run English chat-route benchmark and print summary metrics.")
    parser.add_argument("--router-v2", choices=["0", "1"], default="1")
    parser.add_argument("--min-intent-accuracy", type=float, default=0.95)
    parser.add_argument("--min-answer-source-accuracy", type=float, default=0.95)
    parser.add_argument(
        "--dataset",
        default=str(DEFAULT_DATASET_PATH),
        help="Path to benchmark dataset JSON.",
    )
    parser.add_argument(
        "--output-json",
        default="",
        help="Optional path to persist benchmark report JSON.",
    )
    parser.add_argument(
        "--append-jsonl",
        default="",
        help="Optional path to append one-line JSON benchmark history.",
    )
    args = parser.parse_args()

    os.environ["AI_ROUTER_V2_ENABLED"] = args.router_v2
    svc = _service()
    dataset = _load_dataset(args.dataset)

    total = len(dataset)
    intent_ok = 0
    source_ok = 0
    deterministic = 0
    clarification = 0
    misses = []

    for row in dataset:
        resp = _ask(svc, row["prompt"])
        actual_intent = resp.get("intent", "")
        actual_source = resp.get("answer_source", "")
        if actual_intent == row["intent"]:
            intent_ok += 1
        else:
            misses.append({"prompt": row["prompt"], "field": "intent", "expected": row["intent"], "actual": actual_intent})
        if actual_source == row["source"]:
            source_ok += 1
        else:
            misses.append({"prompt": row["prompt"], "field": "answer_source", "expected": row["source"], "actual": actual_source})
        if actual_source.startswith("deterministic"):
            deterministic += 1
        if actual_source == "clarification":
            clarification += 1

    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "router_v2": args.router_v2,
        "dataset": args.dataset,
        "samples": total,
        "intent_accuracy": round(intent_ok / total, 3),
        "answer_source_accuracy": round(source_ok / total, 3),
        "deterministic_rate": round(deterministic / total, 3),
        "clarification_rate": round(clarification / total, 3),
        "miss_count": len(misses),
        "misses": misses[:20],
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if args.output_json:
        with open(args.output_json, "w", encoding="utf-8") as fp:
            json.dump(report, fp, ensure_ascii=False, indent=2)
            fp.write("\n")
    if args.append_jsonl:
        with open(args.append_jsonl, "a", encoding="utf-8") as fp:
            fp.write(json.dumps(report, ensure_ascii=False))
            fp.write("\n")

    if report["intent_accuracy"] < args.min_intent_accuracy:
        raise SystemExit(
            f"intent_accuracy {report['intent_accuracy']:.3f} is below threshold {args.min_intent_accuracy:.3f}"
        )
    if report["answer_source_accuracy"] < args.min_answer_source_accuracy:
        raise SystemExit(
            "answer_source_accuracy "
            f"{report['answer_source_accuracy']:.3f} is below threshold {args.min_answer_source_accuracy:.3f}"
        )


if __name__ == "__main__":
    main()
