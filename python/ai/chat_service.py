import json

from .explainers import build_chat_prompt
from .intent_router import IntentRouter
from .schemas import build_chat_response
from .validators import sanitize_history, sanitize_spending_summary, clamp_str


class ChatService:
    def __init__(self, generate_reply, get_detailed_snapshot):
        self.generate_reply = generate_reply
        self.get_detailed_snapshot = get_detailed_snapshot
        self.router = IntentRouter()

    def _extract_json_object(self, text):
        if not isinstance(text, str):
            return None
        stripped = text.strip()
        if not stripped:
            return None
        try:
            return json.loads(stripped)
        except Exception:
            pass
        start = stripped.find("{")
        end = stripped.rfind("}")
        if start >= 0 and end > start:
            try:
                return json.loads(stripped[start : end + 1])
            except Exception:
                return None
        return None

    def _summary_to_text(self, summary):
        if not isinstance(summary, dict):
            return "No summary available."
        totals = summary.get("totals") or {}
        categories = summary.get("top_expense_categories") or []
        cat_text = ", ".join(
            f"{c.get('category')} ${float(c.get('amount', 0)):.0f}" for c in categories[:5]
        ) or "none"
        return (
            f"30d income: ${float(totals.get('income_30d', 0)):.2f}; "
            f"30d expenses: ${float(totals.get('expenses_30d', 0)):.2f}; "
            f"tx_count_30d: {int(totals.get('tx_count_30d', 0))}; "
            f"expense_tx_count_30d: {int(totals.get('expense_tx_count_30d', 0))}; "
            f"top categories: {cat_text}"
        )

    def _fallback_reply(self, intent, summary):
        totals = (summary or {}).get("totals") if isinstance(summary, dict) else {}
        if not isinstance(totals, dict):
            totals = {}
        expenses = float(totals.get("expenses_30d", 0) or 0)
        income = float(totals.get("income_30d", 0) or 0)
        if expenses <= 0 and income <= 0:
            return "I do not have enough recent data yet. Connect and refresh transactions, then ask again."
        if intent == "compare":
            return f"I can compare trends using available data: 30-day income ${income:.0f} vs expenses ${expenses:.0f}."
        if intent == "what_if":
            return "Given current snapshot, a lower discretionary spend should improve month-end cash flow."
        if intent == "planning":
            return "Start with a fixed monthly target, cap top spending categories, and review weekly."
        return f"Based on your recent snapshot: income ${income:.0f}, expenses ${expenses:.0f} over 30 days."

    def handle_chat(self, payload, user_id=None):
        payload = payload or {}
        message = clamp_str(payload.get("prompt", ""), 4000)
        if not message:
            raise ValueError("Missing prompt")

        history = sanitize_history(payload.get("history"), max_turns=6)
        summary = sanitize_spending_summary(payload.get("spending_summary"))
        intent = self.router.classify(message, history)
        summary_meta = (summary or {}).get("totals") or {}
        tx_count_30d = int(summary_meta.get("tx_count_30d", 0) or 0)
        summary_empty = summary is None

        context_source = "frontend_summary"
        used_summary = summary is not None

        needs_detail = summary is None and intent in ("compare", "what_if", "planning")
        if needs_detail and user_id:
            context_text = self.get_detailed_snapshot(user_id)
            context_source = "server_snapshot"
            used_summary = False
        else:
            context_text = self._summary_to_text(summary)

        prompt = build_chat_prompt(intent, message, history, context_text)

        try:
            reply = self.generate_reply(prompt, generation_config={"temperature": 0.5, "maxOutputTokens": 350})
            parsed = self._extract_json_object(reply)
            if isinstance(parsed, dict) and isinstance(parsed.get("reply"), str):
                reply_text = clamp_str(parsed.get("reply", ""), 700) or self._fallback_reply(intent, summary)
            else:
                reply_text = clamp_str(reply, 700) or self._fallback_reply(intent, summary)
        except Exception:
            context_source = "rule_fallback"
            reply_text = self._fallback_reply(intent, summary)

        return build_chat_response(
            reply=reply_text,
            intent=intent,
            context_source=context_source,
            used_summary=used_summary,
            tx_count_30d=tx_count_30d,
            summary_empty=summary_empty,
        )

