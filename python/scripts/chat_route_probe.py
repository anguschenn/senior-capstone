#!/usr/bin/env python3
import argparse
import json
import os
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
        "top_expense_categories": [{"category": "Subscriptions", "amount": 131}],
        "recent_transactions": [
            {"date": "2026-05-08", "name": "Netflix", "amount": -15.99},
            {"date": "2026-05-07", "name": "Uber", "amount": -12.5},
        ],
        "totals": {"tx_count_30d": 22, "income_30d": 3898, "expenses_30d": 3842},
    }


def _probe(prompt: str) -> dict[str, Any]:
    svc = _service()
    return svc.handle_chat(
        {"prompt": prompt, "history": [], "spending_summary": _sample_summary()},
        user_id="probe-user",
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Probe chat routing/answer metadata for prompts.")
    parser.add_argument(
        "--router-v2",
        choices=["0", "1"],
        default="1",
        help="Set AI_ROUTER_V2_ENABLED for this probe run.",
    )
    parser.add_argument("prompts", nargs="+", help="Prompt strings to probe.")
    args = parser.parse_args()

    os.environ["AI_ROUTER_V2_ENABLED"] = args.router_v2

    for prompt in args.prompts:
        resp = _probe(prompt)
        row = {
            "prompt": prompt,
            "intent": resp.get("intent"),
            "answer_source": resp.get("answer_source"),
            "period_resolved": resp.get("period_resolved"),
            "facts_used": resp.get("facts_used", []),
            "reply": resp.get("reply", ""),
        }
        print(json.dumps(row, ensure_ascii=False))


if __name__ == "__main__":
    main()
