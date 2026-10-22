import os
import re
from datetime import date as date_cls

from config import AI_REWRITE_ENABLED, AI_ROUTER_V2_ENABLED

from .explainers import build_chat_prompt
from .intent_router import IntentRouter
from .parsers import extract_json_object
from .query_executors_v2 import _month_scale as month_scale
from .query_executors_v2 import execute_plan_v2
from .query_parser_v2 import (
    _categories_in,
    _month_range_spec,
    _named_month_keys,
    _normalize,
    asks_for_advice,
    category_named,
    credit_card_scope,
    parse_query_v2,
)
from .query_planner_v2 import build_execution_plan_v2
from .response_utils import describe_plaid_amount, group_dollar_amounts
from .response_validator_v2 import validate_v2_response
from .schemas import build_chat_response
from .time_parsing import (
    extract_month_range_keys,
    extract_specific_date_key,
    extract_specific_month_key,
    month_mentions,
    previous_month_key,
    previous_year_key,
)
from .time_scope_resolver import (
    previous_month_key as resolve_previous_month_key,
)
from .time_scope_resolver import (
    selected_month_key as resolve_selected_month_key,
)
from .validators import clamp_str, sanitize_history, sanitize_spending_summary

# Asks with one right answer from the user's data: these can be answered
# deterministically once their period is known.
FACTUAL_INTENTS = frozenset(
    {
        "amount_lookup",
        "top_category_lookup",
        "month_overview",
        "compare_periods",
        "recent_transactions",
        "category_spending",
    }
)


class _CategoryFigures(dict):
    """{category: figures} that also carries each category's whole amounts in .bases."""

    def __init__(self):
        super().__init__()
        self.bases = {}


class ChatService:
    """Orchestrates AI chat with validated financial context and safe fallbacks."""

    HIGH_CONFIDENCE_THRESHOLD = 0.70
    MID_CONFIDENCE_THRESHOLD = 0.45

    def __init__(self, generate_reply, get_detailed_snapshot, rewrite_cache=None):
        self.generate_reply = generate_reply
        self.get_detailed_snapshot = get_detailed_snapshot
        # get(message) -> str | None and put(message, rewritten); see ai/rewrite_cache.py.
        self.rewrite_cache = rewrite_cache
        self.router = IntentRouter(classify_with_llm=generate_reply)

    def _rewrite_enabled(self):
        """Model rewrite of unrecognised questions; AI_REWRITE_ENABLED=0 turns it off."""
        return AI_REWRITE_ENABLED

    def _router_v2_enabled(self):
        env_value = os.getenv("AI_ROUTER_V2_ENABLED")
        if isinstance(env_value, str) and env_value.strip():
            return env_value.strip() in {"1", "true", "TRUE"}
        return bool(AI_ROUTER_V2_ENABLED)

    def _summary_to_text(self, summary):
        """Convert structured summary JSON into compact prompt context text."""
        if not isinstance(summary, dict):
            return "No summary available."
        totals = summary.get("totals") or {}
        categories = summary.get("top_expense_categories") or []
        recent = summary.get("recent_transactions") or []
        cat_text = (
            ", ".join(
                f"{c.get('category')} ${float(c.get('amount', 0)):.0f}" for c in categories[:5]
            )
            or "none"
        )
        recent_text = (
            ", ".join(
                f"{t.get('date')} {t.get('name')} {describe_plaid_amount(t.get('amount'))}"
                for t in recent[:5]
            )
            or "none"
        )
        annual = (
            summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
        )
        annual_totals = annual.get("totals") if isinstance(annual.get("totals"), dict) else {}
        annual_categories = (
            annual.get("top_expense_categories_year")
            if isinstance(annual.get("top_expense_categories_year"), list)
            else []
        )
        monthly_expense_ranking = (
            annual.get("monthly_expense_ranking")
            if isinstance(annual.get("monthly_expense_ranking"), list)
            else []
        )
        monthly_expense_trend = (
            annual.get("monthly_expense_trend")
            if isinstance(annual.get("monthly_expense_trend"), list)
            else []
        )
        annual_cat_text = (
            ", ".join(
                f"{c.get('category')} ${float(c.get('amount', 0)):.0f}"
                for c in annual_categories[:5]
            )
            or "none"
        )
        high_month_text = (
            ", ".join(
                f"{m.get('month')} ${float(m.get('expenses', 0)):.0f}"
                for m in monthly_expense_ranking[:3]
                if isinstance(m, dict)
            )
            or "none"
        )
        trend_tail = (
            monthly_expense_trend[-3:] if len(monthly_expense_trend) > 3 else monthly_expense_trend
        )
        trend_text = (
            ", ".join(self._trend_point(m) for m in trend_tail if isinstance(m, dict)) or "none"
        )
        month_index = (
            summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
        )
        rankings = summary.get("rankings") if isinstance(summary.get("rankings"), dict) else {}
        top_months = (
            rankings.get("highest_spending_months")
            if isinstance(rankings.get("highest_spending_months"), list)
            else []
        )
        top_days_recent = (
            rankings.get("highest_spending_days_recent")
            if isinstance(rankings.get("highest_spending_days_recent"), list)
            else []
        )
        if not top_months:
            top_months = [
                {"month": k, "expenses": (v.get("expenses", 0) if isinstance(v, dict) else 0)}
                for k, v in month_index.items()
            ]
            top_months.sort(
                key=lambda x: float((x or {}).get("expenses", 0) or 0),
                reverse=True,
            )
        v2_month_text = (
            ", ".join(
                f"{clamp_str(m.get('month', ''), 16)} ${float(m.get('expenses', 0)):.0f}"
                for m in top_months[:3]
                if isinstance(m, dict) and clamp_str(m.get("month", ""), 16)
            )
            or "none"
        )
        v2_day_text = (
            ", ".join(
                f"{clamp_str(d.get('date', ''), 16)} ${float(d.get('expenses', 0)):.0f}"
                for d in top_days_recent[:3]
                if isinstance(d, dict) and clamp_str(d.get("date", ""), 16)
            )
            or "none"
        )
        year = int(annual.get("year", 0) or 0)
        annual_text = (
            f"; year: {year}; "
            f"income_year: ${float(annual_totals.get('income_year', 0)):.2f}; "
            f"expenses_year: ${float(annual_totals.get('expenses_year', 0)):.2f}; "
            f"expense_tx_count_year: {int(annual_totals.get('expense_tx_count_year', 0))}; "
            f"top categories year: {annual_cat_text}; "
            f"high expense months: {high_month_text}; "
            f"recent monthly trend: {trend_text}; "
            f"v2 highest spending months: {v2_month_text}; "
            f"v2 highest spending days recent: {v2_day_text}"
        )

        # Ready-made figures so the model quotes numbers instead of doing arithmetic.
        savings_parts = []
        for c in categories[:5]:
            name = clamp_str(c.get("category", ""), 64)
            amount = float(c.get("amount", 0) or 0)
            if not name or amount <= 0 or self._is_transfer_category(name):
                continue
            savings_parts.append(
                f"{name} 10% = ${amount * 0.1:.0f}/month, 20% = ${amount * 0.2:.0f}/month"
            )
            if len(savings_parts) == 3:
                break
        savings_text = "; ".join(savings_parts) or "none"
        month_text = (
            f"selected month so far: income ${float(totals.get('income_month', 0)):.2f}, "
            f"expenses ${float(totals.get('expenses_month', 0)):.2f}, "
            f"net ${float(totals.get('net_month', 0)):.2f}"
        )
        factor, progress = month_scale(self._selected_month_key(summary))
        if progress:
            month_text += (
                f" ({progress[0]} of {progress[1]} days; expenses on pace for about "
                f"${float(totals.get('expenses_month', 0) or 0) * factor:.0f} for the full month)"
            )
        scope_text = ""
        if summary.get("scope") == "single_account":
            label = clamp_str(summary.get("scope_label", ""), 64) or "the selected account"
            scope_text = f"account: only {label}; "
            if credit_card_scope(summary):
                # Money into a card is its payments and refunds; the model must not call
                # that income or savings.
                scope_text += (
                    "this is a credit card, so 'income' below is card payments and refunds, "
                    "not income; never describe it as income, earnings or savings; "
                )
        # Month-end budget overruns (server summary only, ai/server_summary.py), so advice
        # can say "Food went over in 3 of the last 6 months".
        overruns = [
            f"{a.get('month')} {a.get('category')} ${float(a.get('spent', 0)):.0f} "
            f"of ${float(a.get('limit', 0)):.0f} limit"
            for a in (summary.get("alert_history") or [])
            if a.get("kind") == "over_budget"
        ]
        if overruns:
            scope_text += f"months that ended over budget: {', '.join(overruns[:12])}; "
        return (
            f"{scope_text}{month_text}; "
            f"savings options from cutting 30d category spend: {savings_text}; "
            f"30d income: ${float(totals.get('income_30d', 0)):.2f}; "
            f"30d expenses: ${float(totals.get('expenses_30d', 0)):.2f}; "
            f"tx_count_30d: {int(totals.get('tx_count_30d', 0))}; "
            f"expense_tx_count_30d: {int(totals.get('expense_tx_count_30d', 0))}; "
            f"top categories last 30 days: {cat_text}; "
            f"recent transactions: {recent_text}"
            f"{annual_text}"
        )

    @staticmethod
    def _trend_point(point):
        """ "2026-09 1880", or "2026-10 1017 so far (19 of 31 days, on pace for about 1659)"
        so the model doesn't compare an unfinished month with full ones."""
        month = point.get("month")
        expenses = float(point.get("expenses", 0) or 0)
        factor, progress = month_scale(month)
        if not progress:
            return f"{month} {expenses:.0f}"
        return (
            f"{month} {expenses:.0f} so far ({progress[0]} of {progress[1]} days, "
            f"on pace for about {expenses * factor:.0f})"
        )

    def _fallback_reply(self, intent, summary, message="", query_spec=None):
        """Return deterministic reply when model output is unavailable/invalid."""
        message_text = clamp_str(message or "", 4000).lower()
        if intent in {"planning", "general"} and asks_for_advice(message or ""):
            # Advice the model couldn't ground: one concrete, priced step instead of totals.
            asked = category_named(message or "", summary) if isinstance(summary, dict) else ""
            month_index = summary.get("month_index") if isinstance(summary, dict) else None
            if asked and isinstance(month_index, dict):
                selected = self._selected_month_key(summary)
                months = sorted(k for k in month_index if k < selected)[-3:]
                values = [
                    float(((month_index.get(k) or {}).get("categories") or {}).get(asked, 0) or 0)
                    for k in months
                ]
                usual = sum(values) / len(values) if values else 0.0
                if usual >= 1:
                    span = months[0] if len(months) == 1 else f"{months[0]} to {months[-1]}"
                    return (
                        f"{asked} averages about ${usual:.0f} a month ({span}). Spending 10% less "
                        f"there saves about ${usual * 0.1:.0f} a month, and 20% less about "
                        f"${usual * 0.2:.0f}."
                    )
            target = self._best_spend_target(summary, message or "")
            if target:
                amount = target["amount"]
                return (
                    f"{target['name']} is your biggest spending area at about ${amount:.0f} over "
                    f"the last 30 days, so it's the best place to start: spending 10% less there "
                    f"saves about ${amount * 0.1:.0f} a month, and 20% less about "
                    f"${amount * 0.2:.0f}."
                )
        spec = query_spec if isinstance(query_spec, dict) else {}
        totals = (summary or {}).get("totals") if isinstance(summary, dict) else {}
        if not isinstance(totals, dict):
            totals = {}
        month_index = (summary or {}).get("month_index") if isinstance(summary, dict) else {}
        if not isinstance(month_index, dict):
            month_index = {}
        year_index = (summary or {}).get("year_index") if isinstance(summary, dict) else {}
        if not isinstance(year_index, dict):
            year_index = {}
        annual = (summary or {}).get("annual_summary") if isinstance(summary, dict) else {}
        if not isinstance(annual, dict):
            annual = {}
        annual_totals = annual.get("totals") if isinstance(annual.get("totals"), dict) else {}
        if not isinstance(annual_totals, dict):
            annual_totals = {}
        annual_categories = (
            annual.get("top_expense_categories_year")
            if isinstance(annual.get("top_expense_categories_year"), list)
            else []
        )

        expenses = float(totals.get("expenses_30d", 0) or 0)
        income = float(totals.get("income_30d", 0) or 0)
        annual_income = float(annual_totals.get("income_year", 0) or 0)
        annual_expenses = float(annual_totals.get("expenses_year", 0) or 0)
        annual_expense_tx = int(annual_totals.get("expense_tx_count_year", 0) or 0)
        annual_year = int(annual.get("year", 0) or 0)

        annual_has_signal = annual_income > 0 or annual_expenses > 0 or annual_expense_tx > 0
        annual_top_text = ", ".join(
            f"{c.get('category')} ${float(c.get('amount', 0)):.0f}" for c in annual_categories[:3]
        )

        period_type = clamp_str(spec.get("period_type", ""), 24)
        period_key = clamp_str(spec.get("period_key", ""), 64)
        month_key = ""
        if period_type == "month" and period_key:
            month_key = period_key
        elif "last month" in message_text:
            month_key = self._previous_month_key(summary) or ""
        elif "this month" in message_text:
            month_key = self._selected_month_key(summary)

        if month_key:
            month_row = month_index.get(month_key)
            if isinstance(month_row, dict):
                month_income = float(month_row.get("income", 0) or 0)
                month_expenses = float(month_row.get("expenses", 0) or 0)
                if "increase" in message_text:
                    prev_key = ""
                    parts = month_key.split("-")
                    if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
                        y = int(parts[0])
                        m = int(parts[1])
                        if 1 <= m <= 12:
                            prev_y = y if m > 1 else y - 1
                            prev_m = m - 1 if m > 1 else 12
                            prev_key = f"{prev_y:04d}-{prev_m:02d}"
                    prev_row = month_index.get(prev_key)
                    if isinstance(prev_row, dict):
                        prev_expenses = float(prev_row.get("expenses", 0) or 0)
                        delta = month_expenses - prev_expenses
                        direction = "increased" if delta >= 0 else "decreased"
                        return (
                            f"Based on {month_key}: income ${month_income:.0f}, expenses "
                            f"${month_expenses:.0f}. Compared with {prev_key}, expenses "
                            f"{direction} by ${abs(delta):.0f}."
                        )
                if credit_card_scope(summary):
                    return f"Based on {month_key}: spending ${month_expenses:.0f}."
                return (
                    f"Based on {month_key}: income ${month_income:.0f}, expenses "
                    f"${month_expenses:.0f}."
                )

        year_key = ""
        if period_type == "year" and period_key:
            year_key = period_key
        elif "last year" in message_text:
            year_key = self._previous_year_key()
        elif "this year" in message_text:
            year_key = str(date_cls.today().year)
        if year_key:
            year_row = year_index.get(year_key)
            if isinstance(year_row, dict):
                year_income = float(year_row.get("income", 0) or 0)
                year_expenses = float(year_row.get("expenses", 0) or 0)
                return (
                    f"Based on {year_key}: income ${year_income:.0f}, expenses "
                    f"${year_expenses:.0f}."
                )

        if expenses <= 0 and income <= 0:
            if annual_has_signal:
                top_suffix = f" Top categories: {annual_top_text}." if annual_top_text else ""
                return (
                    f"Recent 30-day activity is low, but in {annual_year} so far "
                    f"you have income ${annual_income:.0f} and expenses ${annual_expenses:.0f} "
                    f"across {annual_expense_tx} expense transactions.{top_suffix}"
                )
            return "I do not have enough recent data yet. Connect and refresh transactions, then ask again."
        if intent == "compare_periods":
            return f"I can compare trends using available data: 30-day income ${income:.0f} vs expenses ${expenses:.0f}."
        if intent == "what_if":
            return "Given current snapshot, a lower discretionary spend should improve month-end cash flow."
        if intent == "planning":
            return (
                "Start with a fixed monthly target, cap top spending categories, and review weekly."
            )
        if credit_card_scope(summary):
            # Money into a card is payments and refunds, not income.
            return f"Over the last 30 days, spending on this card was about ${expenses:.0f}."
        return (
            f"Based on your recent snapshot (last 30 days): income ${income:.0f}, "
            f"expenses ${expenses:.0f}."
        )

    def _split_points(self, text, max_items=3):
        """Split a mixed bullet/line text block into clean short list items."""
        if not isinstance(text, str):
            return []
        normalized = text.replace("\r\n", "\n").replace("\r", "\n")
        chunks = []
        for line in normalized.split("\n"):
            part = line.strip().lstrip("-•* ").strip()
            if not part:
                continue
            for seg in part.split(";"):
                item = clamp_str(seg.strip(), 220)
                if item:
                    chunks.append(item)
        return chunks[:max_items]

    def _parse_structured_text(self, text):
        """Parse non-JSON model output that follows Answer/Why/Next sections."""
        if not isinstance(text, str):
            return "", [], []

        reply = clamp_str(text, 2500)
        insights = []
        actions = []
        answer_parts = []
        mode = "answer"

        # Some smaller local models occasionally return truncated JSON-like text.
        # Try to salvage a user-safe reply instead of leaking raw JSON fragments.
        jsonish_candidate = ""
        jsonish_reply_match = re.search(r'"reply"\s*:\s*"([^"]+)"', text, flags=re.IGNORECASE)
        if jsonish_reply_match:
            candidate = clamp_str(jsonish_reply_match.group(1).strip(), 2500)
            if candidate:
                jsonish_candidate = candidate
                reply = candidate

        lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        for raw_line in lines:
            line = raw_line.strip()
            if not line:
                continue
            lower = line.lower()
            if lower.startswith("answer:"):
                mode = "answer"
                value = line.split(":", 1)[1].strip()
                if value:
                    answer_parts.append(value)
                continue
            if lower.startswith("why:"):
                mode = "why"
                value = line.split(":", 1)[1].strip()
                if value:
                    insights.extend(self._split_points(value, max_items=3))
                continue
            if lower.startswith("next:"):
                mode = "next"
                value = line.split(":", 1)[1].strip()
                if value:
                    actions.extend(self._split_points(value, max_items=3))
                continue

            if mode == "why":
                insights.extend(self._split_points(line, max_items=3))
            elif mode == "next":
                actions.extend(self._split_points(line, max_items=3))
            else:
                answer_parts.append(line)

        if answer_parts:
            reply = clamp_str(" ".join(answer_parts), 2500)
        # If there is no structured section and content looks like JSON-ish blob,
        # prioritize the extracted candidate from the reply field.
        if text.strip().startswith("{") and jsonish_candidate:
            reply = jsonish_candidate
        return reply, insights[:3], actions[:3]

    def _last_assistant_reply(self, history):
        """Get the latest assistant message from sanitized history."""
        if not isinstance(history, list):
            return ""
        for turn in reversed(history):
            if not isinstance(turn, dict):
                continue
            if (turn.get("role") or "").lower() != "assistant":
                continue
            text = clamp_str(turn.get("text", ""), 2500)
            if text:
                return text
        return ""

    def _dedupe_reply(self, reply_text, history, summary):
        """Avoid returning the same wording repeatedly across adjacent turns."""
        last_reply = self._last_assistant_reply(history)
        if not last_reply:
            return reply_text
        if (reply_text or "").strip().lower() != last_reply.strip().lower():
            return reply_text

        categories = []
        if isinstance(summary, dict):
            raw = summary.get("top_expense_categories")
            if isinstance(raw, list):
                categories = [c for c in raw if isinstance(c, dict)]
        if categories:
            top = categories[0]
            top_name = clamp_str(top.get("category", ""), 64) or "your top category"
            return clamp_str(
                f"{reply_text} A fresh angle: set a weekly cap for {top_name} and review it mid-week.",
                2500,
            )
        return clamp_str(
            f"{reply_text} A fresh angle: compare this week versus last week and adjust one discretionary category.",
            2500,
        )

    _DOLLAR_RE = re.compile(r"\$\s?(\d[\d,]*(?:\.\d+)?)")
    _NUMBER_RE = re.compile(r"\d[\d,]*(?:\.\d+)?")

    def _allowed_amounts(self, context_text, message=""):
        """Dollar amounts in the data, plus any number the user typed. Counts and dates in
        the data don't qualify, so "$18" can't borrow its legitimacy from "2026-10-18"."""
        values = set()
        sources = [(context_text, self._DOLLAR_RE), (message, self._NUMBER_RE)]
        for text, pattern in sources:
            for raw in pattern.findall(str(text or "")):
                try:
                    values.add(float(raw.replace(",", "")))
                except ValueError:
                    continue
        return values

    def _category_amounts(self, summary):
        """{category: amounts that belong to it} from the figures the model was given.
        Its .bases holds each category's whole amounts (not the 10/15/20% shares)."""
        out = _CategoryFigures()
        categories = []
        if isinstance(summary, dict):
            categories = summary.get("top_expense_categories") or []
        for item in categories or []:
            if not isinstance(item, dict):
                continue
            name = clamp_str(item.get("category", ""), 64)
            amount = float(item.get("amount", 0) or 0)
            if name and amount > 0:
                out[name.lower()] = {
                    round(amount),
                    round(amount * 0.1),
                    round(amount * 0.2),
                    round(amount * 0.15),
                }
                out.bases.setdefault(name.lower(), set()).add(amount)
        # Every category's monthly totals too, so "$94 for entertainment" (Food's 10%) is
        # caught even when entertainment isn't among the top categories.
        month_index = summary.get("month_index") if isinstance(summary, dict) else None
        for row in (month_index or {}).values() if isinstance(month_index, dict) else []:
            cats = row.get("categories") if isinstance(row, dict) else None
            for name, amount in (cats or {}).items() if isinstance(cats, dict) else []:
                amount = float(amount or 0)
                if name and amount > 0:
                    # Month totals only: the model is handed 10%/20% figures for the last
                    # 30 days, not for every month, and extra shares invite coincidences.
                    out.setdefault(str(name).lower(), set()).add(round(amount))
                    out.bases.setdefault(str(name).lower(), set()).add(amount)
        return out

    def _amounts_grounded(self, text, allowed, by_category=None):
        """True when every dollar figure in text matches a number in the data (within 1%),
        and, when the text names exactly one category, belongs to that category."""
        text = str(text or "")
        values = []
        for raw in self._DOLLAR_RE.findall(text):
            try:
                values.append(float(raw.replace(",", "")))
            except ValueError:
                return False
        for value in values:
            if not any(abs(value - a) <= max(1.0, abs(a) * 0.01) for a in allowed):
                return False
        if by_category and values:
            lowered = text.lower()
            named = [c for c in by_category if re.search(r"\b" + re.escape(c) + r"\b", lowered)]
            # "20% reduction = $94" must be 20% of the category, not its 10% figure.
            # Shares are checked against whole amounts only, so "20% ... $37" can't pass as
            # 20% of a $187 that is itself a share.
            whole = getattr(by_category, "bases", None) or by_category
            bases = [b for c in (named if len(named) == 1 else whole) for b in whole.get(c, ())]
            for pct, raw in re.findall(r"(\d{1,3})\s*%[^$.;]{0,30}?\$(\d[\d,]*(?:\.\d+)?)", text):
                share = float(raw.replace(",", ""))
                part = float(pct) / 100
                if bases and not any(
                    abs(share - b * part) <= max(1.0, b * part * 0.02) for b in bases
                ):
                    return False
            if len(named) == 1:
                own = by_category[named[0]]
                others = set().union(*(v for k, v in by_category.items() if k != named[0]))
                for value in values:
                    if round(value) in others and not any(abs(value - o) <= 1 for o in own):
                        return False  # "Food ... $31" where $31 is Transport's figure
        return True

    def _drop_ungrounded_sentences(self, text, allowed, by_category=None):
        sentences = re.split(r"(?<=[.!?])\s+", str(text or "").strip())
        return " ".join(
            x for x in sentences if x and self._amounts_grounded(x, allowed, by_category)
        ).strip()

    def _is_transfer_category(self, name):
        """Classify transfer/internal categories to avoid bad advice targets."""
        text = clamp_str(name or "", 128).lower()
        if not text:
            return False
        return "transfer" in text or "internal" in text

    def _best_spend_target(self, summary, message=""):
        """Pick the best discretionary spend category candidate for action text: the one
        the question is about when it names one, else the biggest."""
        if not isinstance(summary, dict):
            return None
        categories = summary.get("top_expense_categories")
        if not isinstance(categories, list):
            return None
        asked = category_named(message, summary) if message else ""
        if asked:
            for item in categories:
                if not isinstance(item, dict):
                    continue
                if str(item.get("category", "")).lower() != asked.lower():
                    continue
                amount = float(item.get("amount", 0) or 0)
                if amount > 0:
                    return {"name": str(item["category"]), "amount": amount}
        for item in categories:
            if not isinstance(item, dict):
                continue
            name = clamp_str(item.get("category", ""), 64)
            amount = float(item.get("amount", 0) or 0)
            if not name or amount <= 0:
                continue
            if self._is_transfer_category(name):
                continue
            return {"name": name, "amount": amount}
        return None

    def _has_quantified_action(self, actions):
        """Detect whether at least one action already includes measurable scope."""
        if not isinstance(actions, list):
            return False
        for action in actions:
            if not isinstance(action, str):
                continue
            text = action.strip()
            if "$" in text:
                return True
            if any(ch.isdigit() for ch in text):
                return True
        return False

    # Only advice-like answers get a savings target appended; an off-topic or
    # general reply ("weather tomorrow") should not end with "reduce Food by 15%".
    SAVINGS_ACTION_INTENTS = {"planning", "explain", "what_if", "compare_periods"}

    def _enforce_action_quality(self, actions, summary, intent=None, message=""):
        """Ensure at least one actionable, quantified recommendation exists."""
        current = [clamp_str(x, 220) for x in (actions or []) if isinstance(x, str) and x.strip()]
        current = current[:3]
        if intent is not None and intent not in self.SAVINGS_ACTION_INTENTS:
            return current
        if self._has_quantified_action(current):
            return current

        target = self._best_spend_target(summary, message)
        if target:
            monthly = target["amount"]
            lower = max(5.0, round(monthly * 0.15, 2))
            upper = max(lower, round(monthly * 0.2, 2))
            quantified = clamp_str(
                f"Cut {target['name']} by 15-20% this month to save about ${lower:.0f}-${upper:.0f}.",
                220,
            )
        else:
            quantified = "For the next 14 days, cut one discretionary category by 10% and target at least $30 in savings."

        if len(current) < 3:
            current.append(quantified)
        elif current:
            current[-1] = quantified
        else:
            current = [quantified]
        return current[:3]

    def _sanitize_insights_accuracy(self, insights):
        """Remove high-risk derived claims (daily averages/frequency counts)."""
        if not isinstance(insights, list):
            return []
        sanitized = []
        for insight in insights:
            if not isinstance(insight, str):
                continue
            text = clamp_str(insight, 220)
            if not text:
                continue
            lower = text.lower()
            has_number = re.search(r"(\$?\d+(\.\d+)?)", lower) is not None
            risky_rate_claim = ("per day" in lower or "average" in lower) and has_number
            risky_frequency_claim = (
                " times " in f" {lower} " or "times recently" in lower or "times this" in lower
            ) and has_number
            if risky_rate_claim or risky_frequency_claim:
                sanitized.append(
                    "Spending pressure appears concentrated in a few discretionary categories in your recent summary."
                )
            else:
                sanitized.append(self._sanitize_claim_text(text))
        return sanitized[:3]

    def _sanitize_claim_text(self, text):
        """Downgrade high-risk numeric claims into safer non-numeric wording."""
        value = clamp_str(text or "", 2500)
        if not value:
            return value
        lower = value.lower()
        has_number = re.search(r"(\$?\d+(\.\d+)?)", lower) is not None
        risky_rate_claim = ("per day" in lower or "average" in lower) and has_number
        risky_frequency_claim = (
            " times " in f" {lower} " or "times recently" in lower or "times this" in lower
        ) and has_number
        # Generic consistency guard: when text states a total and also mentions
        # component dollar amounts, no component should exceed the total.
        total_match = re.search(r"\btotal\s+\$([0-9]+(?:\.[0-9]+)?)", lower)
        if total_match:
            total = float(total_match.group(1))
            dollar_values = [
                float(m.group(1)) for m in re.finditer(r"\$([0-9]+(?:\.[0-9]+)?)", lower)
            ]
            component_values = [v for v in dollar_values if abs(v - total) > 1e-9]
            if any(v > total for v in component_values):
                return (
                    "Category composition in this response looks inconsistent with the total; "
                    "ask for a category breakdown from summary indexes."
                )
        if risky_rate_claim or risky_frequency_claim:
            return "Focus on reducing a few high-pressure discretionary categories over the next 14 days."
        return value

    def _asks_amount(self, message):
        """Detect user questions that explicitly request numeric amount."""
        text = clamp_str(message or "", 4000).lower()
        if not text:
            return False
        if ("how much" in text) or ("amount" in text):
            return True
        if "what did i spend" in text or "what was spent" in text:
            return True
        if re.search(r"\bspend(ing)?\b", text) and (
            re.search(r"\b20\d{2}-\d{2}\b", text)
            or re.search(r"\b(20\d{2})\b", text)
            or month_mentions(text)
        ):
            return True
        return False

    def _asks_top_category(self, message):
        """Detect user questions asking for the highest-spend category."""
        text = clamp_str(message or "", 4000).lower()
        if not text:
            return False
        has_category_term = "category" in text or "categories" in text
        has_top_term = "most" in text or "top" in text or "highest" in text or "max" in text
        if has_category_term and (has_top_term or "spend" in text):
            return True
        if "what category did i spend most on" in text:
            return True
        return False

    def _scope_key(self, summary):
        """Normalize scope label for structured query metadata."""
        if not isinstance(summary, dict):
            return "unknown"
        scope = clamp_str(summary.get("scope", ""), 32)
        if scope:
            return scope
        if clamp_str(summary.get("scope_label", ""), 64):
            return "labeled_scope"
        return "unknown"

    def _extract_query_spec(self, message, summary, fallback_intent):
        """Parse message into a small structured query for deterministic lookup."""
        text = clamp_str(message or "", 4000).lower()
        amount_metric = self._extract_amount_metric(message)
        annual = summary.get("annual_summary") if isinstance(summary, dict) else {}
        if not isinstance(annual, dict):
            annual = {}
        annual_year = int(annual.get("year", 0) or 0)
        if annual_year <= 0:
            annual_year = date_cls.today().year

        if self._asks_month_overview(message):
            period_key = str(annual_year)
            year_hint = re.search(r"\b(20\d{2})\b", text)
            if year_hint:
                period_key = year_hint.group(1)
            return {
                "intent": "month_overview",
                "metric": "expenses",
                "period_type": "year",
                "period_key": period_key,
                "scope": self._scope_key(summary),
            }

        if self._asks_top_category(message):
            range_keys = self._extract_month_range_keys(message, annual_year)
            if len(range_keys) >= 2:
                return {
                    "intent": "top_category_lookup",
                    "metric": "top_category",
                    "period_type": "month_range",
                    "period_key": ",".join(range_keys[:6]),
                    "scope": self._scope_key(summary),
                }
            if "last month" in text:
                last_month = self._previous_month_key(summary)
                if last_month:
                    return {
                        "intent": "top_category_lookup",
                        "metric": "top_category",
                        "period_type": "month",
                        "period_key": last_month,
                        "scope": self._scope_key(summary),
                    }
            month_key = self._extract_specific_month_key(message, annual_year)
            if month_key:
                return {
                    "intent": "top_category_lookup",
                    "metric": "top_category",
                    "period_type": "month",
                    "period_key": month_key,
                    "scope": self._scope_key(summary),
                }
            if "this month" in text:
                return {
                    "intent": "top_category_lookup",
                    "metric": "top_category",
                    "period_type": "month",
                    "period_key": self._selected_month_key(summary),
                    "scope": self._scope_key(summary),
                }
            if "last year" in text:
                return {
                    "intent": "top_category_lookup",
                    "metric": "top_category",
                    "period_type": "year",
                    "period_key": self._previous_year_key(),
                    "scope": self._scope_key(summary),
                }
            if "this year" in text or "year" in text or re.search(r"\b20\d{2}\b", text):
                year_match = re.search(r"\b(20\d{2})\b", text)
                year_key = year_match.group(1) if year_match else str(annual_year)
                return {
                    "intent": "top_category_lookup",
                    "metric": "top_category",
                    "period_type": "year",
                    "period_key": year_key,
                    "scope": self._scope_key(summary),
                }
            return {
                "intent": "top_category_lookup",
                "metric": "top_category",
                "period_type": "unknown",
                "period_key": "",
                "scope": self._scope_key(summary),
            }

        if self._asks_amount(message):
            range_keys = self._extract_month_range_keys(message, annual_year)
            if len(range_keys) >= 2:
                return {
                    "intent": "amount_lookup",
                    "metric": amount_metric,
                    "period_type": "month_range",
                    "period_key": ",".join(range_keys[:6]),
                    "scope": self._scope_key(summary),
                }
            if "last month" in text:
                last_month = self._previous_month_key(summary)
                if last_month:
                    return {
                        "intent": "amount_lookup",
                        "metric": amount_metric,
                        "period_type": "month",
                        "period_key": last_month,
                        "scope": self._scope_key(summary),
                    }
            if "this month" in text:
                return {
                    "intent": "amount_lookup",
                    "metric": amount_metric,
                    "period_type": "month",
                    "period_key": self._selected_month_key(summary),
                    "scope": self._scope_key(summary),
                }
            date_key = self._extract_specific_date_key(message, annual_year)
            if date_key:
                return {
                    "intent": "amount_lookup",
                    "metric": amount_metric,
                    "period_type": "day",
                    "period_key": date_key,
                    "scope": self._scope_key(summary),
                }
            month_key = self._extract_specific_month_key(message, annual_year)
            if month_key:
                return {
                    "intent": "amount_lookup",
                    "metric": amount_metric,
                    "period_type": "month",
                    "period_key": month_key,
                    "scope": self._scope_key(summary),
                }
            if "last 30 days" in text or "30 days" in text or "30d" in text:
                return {
                    "intent": "amount_lookup",
                    "metric": amount_metric,
                    "period_type": "rolling_30d",
                    "period_key": "rolling_30d",
                    "scope": self._scope_key(summary),
                }
            if "last year" in text:
                return {
                    "intent": "amount_lookup",
                    "metric": amount_metric,
                    "period_type": "year",
                    "period_key": self._previous_year_key(),
                    "scope": self._scope_key(summary),
                }
            if "this year" in text or "year" in text or re.search(r"\b20\d{2}\b", text):
                year_match = re.search(r"\b(20\d{2})\b", text)
                year_key = year_match.group(1) if year_match else str(annual_year)
                return {
                    "intent": "amount_lookup",
                    "metric": amount_metric,
                    "period_type": "year",
                    "period_key": year_key,
                    "scope": self._scope_key(summary),
                }
            return {
                "intent": "amount_lookup",
                "metric": amount_metric,
                "period_type": "unknown",
                "period_key": "",
                "scope": self._scope_key(summary),
            }

        return {
            "intent": clamp_str(fallback_intent or "general", 24) or "general",
            "metric": "expenses",
            "period_type": "unknown",
            "period_key": "",
            "scope": self._scope_key(summary),
        }

    def _extract_amount_metric(self, message):
        text = clamp_str(message or "", 4000).lower()
        if not text:
            return "expenses"
        if any(
            token in text
            for token in (
                "income",
                "earn",
                "earned",
                "salary",
                "paycheck",
                "revenue",
            )
        ):
            return "income"
        return "expenses"

    def _has_amount_metric_conflict(self, message):
        text = clamp_str(message or "", 4000).lower()
        if not text:
            return False
        has_income = any(
            token in text for token in ("income", "earn", "earned", "salary", "paycheck", "revenue")
        )
        has_spend = bool(re.search(r"\bspend(ing)?\b", text)) or ("expense" in text)
        return has_income and has_spend

    def _is_strict_income_amount_query(self, message):
        text = clamp_str(message or "", 4000).lower()
        if not text:
            return False
        if self._extract_amount_metric(message) != "income":
            return False
        if self._has_amount_metric_conflict(message):
            return False
        # Require explicit, valid period phrase to avoid over-promoting vague/invalid prompts.
        if (
            "last month" in text
            or "this month" in text
            or "last year" in text
            or "this year" in text
        ):
            return True
        if re.search(r"\b20\d{2}-\d{2}\b", text):
            return True
        return False

    def _scope_label(self, summary):
        """Return account scope label for user-facing clarification."""
        if not isinstance(summary, dict):
            return "this account selection"
        explicit = clamp_str(summary.get("scope_label", ""), 64)
        if explicit:
            return explicit
        scope = clamp_str(summary.get("scope", ""), 32)
        if scope == "all_accounts":
            return "all selected accounts"
        if scope == "single_account":
            return "the selected account"
        return "this account selection"

    def _timeframe_mode(self, message):
        """Infer user-requested window for amount questions."""
        text = clamp_str(message or "", 4000).lower()
        if not text:
            return "unknown"
        # Whole words only: "yearbook", "monthsary" or "todayish" are not time windows.
        if re.search(r"\b(today|yesterday)\b", text):
            return "specific_day"
        if "last 30 days" in text or "30 days" in text or "30d" in text:
            return "rolling_30d"
        if re.search(r"\bwhich months?\b|\bmonths\b", text):
            return "annual_year"
        if re.search(r"\bthis month\b", text):
            return "selected_month"
        if re.search(r"\bmonth(ly)?\b", text):
            return "rolling_30d"
        if re.search(r"\byears?\b|\byearly\b", text):
            return "annual_year"
        if month_mentions(text):
            return "annual_year"
        if re.search(r"\b20\d{2}-\d{2}\b", text):
            return "annual_year"
        return "unknown"

    def _extract_specific_month_key(self, message, default_year):
        """Parse month reference from user message and return YYYY-MM key."""
        return extract_specific_month_key(clamp_str(message or "", 4000), default_year)

    def _selected_month_key(self, summary):
        return resolve_selected_month_key(summary)

    def _previous_month_key(self, summary=None):
        """Return previous month based on selected month when available, else calendar month."""
        resolved = resolve_previous_month_key(summary)
        if not resolved:
            return previous_month_key()
        return resolved

    def _previous_year_key(self):
        """Return previous calendar year as YYYY string."""
        return previous_year_key()

    def _extract_month_range_keys(self, message, default_year):
        """Extract month range keys for phrases like last 3 months."""
        return extract_month_range_keys(clamp_str(message or "", 4000), default_year)

    def _extract_specific_date_key(self, message, default_year):
        """Parse date reference from user message and return YYYY-MM-DD key."""
        return extract_specific_date_key(clamp_str(message or "", 4000), default_year)

    def _has_money_value(self, text):
        """Detect whether assistant reply already contains explicit money value."""
        value = clamp_str(text or "", 2500)
        if not value:
            return False
        if "$" in value:
            return True
        return re.search(r"\b\d{1,3}(,\d{3})*(\.\d+)?\b", value) is not None

    def _asks_month_overview(self, message):
        """Detect questions about high-spend months or month-by-month situation."""
        text = clamp_str(message or "", 4000).lower()
        if not text:
            return False
        if "how much" in text or "amount" in text or "what did i spend" in text:
            return False
        if "which months" in text or "which month" in text:
            return True
        if "monthly spending" in text or "month by month" in text:
            return True
        return "months" in text and "spend" in text

    def _months_overview_anchor(self, summary):
        """Build authoritative month ranking sentence from summary fields."""
        if not isinstance(summary, dict):
            return ""
        rankings = summary.get("rankings")
        if isinstance(rankings, dict):
            top = rankings.get("highest_spending_months")
            if isinstance(top, list):
                normalized = []
                for item in top:
                    if not isinstance(item, dict):
                        continue
                    month = clamp_str(item.get("month", ""), 16)
                    expenses = float(item.get("expenses", 0) or 0)
                    if not month:
                        continue
                    normalized.append((month, expenses))
                normalized = [item for item in normalized if item[1] > 0][:3]
                if normalized:
                    text = ", ".join(f"{month} (${expenses:.0f})" for month, expenses in normalized)
                    return f"Highest spending months for {self._scope_label(summary)}: {text}."
        annual = summary.get("annual_summary")
        if not isinstance(annual, dict):
            month_index = summary.get("month_index")
            if isinstance(month_index, dict):
                rows = []
                for month, item in month_index.items():
                    if not isinstance(item, dict):
                        continue
                    rows.append((clamp_str(month, 16), float(item.get("expenses", 0) or 0)))
                rows.sort(key=lambda x: x[1], reverse=True)
                rows = [row for row in rows if row[1] > 0][:3]
                if rows:
                    text = ", ".join(f"{month} (${expenses:.0f})" for month, expenses in rows)
                    return f"Highest spending months for {self._scope_label(summary)}: {text}."
            return ""
        ranking = annual.get("monthly_expense_ranking")
        if not isinstance(ranking, list):
            return ""
        top = []
        for item in ranking:
            if not isinstance(item, dict):
                continue
            month = clamp_str(item.get("month", ""), 16)
            expenses = float(item.get("expenses", 0) or 0)
            if not month:
                continue
            top.append((month, expenses))
        top = [item for item in top if item[1] > 0][:3]
        if not top:
            return ""
        text = ", ".join(f"{month} (${expenses:.0f})" for month, expenses in top)
        return f"Highest spending months for {self._scope_label(summary)}: {text}."

    def _top_category_anchor(self, summary, message, query_spec=None):
        """Build authoritative top-category answer for month/year queries."""
        if not isinstance(summary, dict):
            return ""
        spec = query_spec if isinstance(query_spec, dict) else {}
        if clamp_str(spec.get("period_type", ""), 24) == "month_range":
            range_keys = [
                clamp_str(x.strip(), 16)
                for x in clamp_str(spec.get("period_key", ""), 128).split(",")
                if clamp_str(x.strip(), 16)
            ]
            if len(range_keys) >= 2:
                annual = (
                    summary.get("annual_summary")
                    if isinstance(summary.get("annual_summary"), dict)
                    else {}
                )
                monthly_top_categories = (
                    annual.get("monthly_top_categories")
                    if isinstance(annual.get("monthly_top_categories"), list)
                    else []
                )
                by_category = {}
                for month_key in range_keys:
                    found = False
                    for item in monthly_top_categories:
                        if not isinstance(item, dict):
                            continue
                        if clamp_str(item.get("month", ""), 16) != month_key:
                            continue
                        category = clamp_str(item.get("category", ""), 64)
                        amount = float(item.get("amount", 0) or 0)
                        if category and amount > 0:
                            by_category[category] = by_category.get(category, 0) + amount
                            found = True
                            break
                    if not found:
                        return ""
                if not by_category:
                    return ""
                top_category, top_amount = sorted(
                    by_category.items(), key=lambda kv: kv[1], reverse=True
                )[0]
                return (
                    f"For {range_keys[0]} to {range_keys[-1]}, based on monthly top-category summaries for "
                    f"{self._scope_label(summary)}, the top category is {top_category} at about ${top_amount:.0f}."
                )
        annual = (
            summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
        )
        spec = query_spec if isinstance(query_spec, dict) else {}
        requested_year = (
            clamp_str(spec.get("period_key", ""), 8)
            if clamp_str(spec.get("period_type", ""), 24) == "year"
            else ""
        )
        annual_year = str(int(annual.get("year", 0) or 0))
        if requested_year and annual_year and requested_year != annual_year:
            return (
                f"I do not see a yearly category breakdown for {requested_year} "
                f"in the current summary for {self._scope_label(summary)}."
            )
        annual_year_int = int(annual.get("year", 0) or 0)
        month_key = self._extract_specific_month_key(message, annual_year_int)
        month_index = (
            summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
        )
        if month_key:
            month_row = month_index.get(month_key)
            if isinstance(month_row, dict):
                top = month_row.get("top_category")
                if isinstance(top, dict):
                    top_name = clamp_str(top.get("name", ""), 64)
                    top_amount = float(top.get("amount", 0) or 0)
                    if top_name and top_amount > 0:
                        return (
                            f"For {month_key}, the top category for {self._scope_label(summary)} "
                            f"is {top_name} at about ${top_amount:.0f}."
                        )
            monthly_top_categories = (
                annual.get("monthly_top_categories")
                if isinstance(annual.get("monthly_top_categories"), list)
                else []
            )
            for item in monthly_top_categories:
                if not isinstance(item, dict):
                    continue
                if clamp_str(item.get("month", ""), 16) != month_key:
                    continue
                category = clamp_str(item.get("category", ""), 64)
                amount = float(item.get("amount", 0) or 0)
                if category and amount > 0:
                    return (
                        f"For {month_key}, the top category for {self._scope_label(summary)} "
                        f"is {category} at about ${amount:.0f}."
                    )
            return (
                f"I do not see a monthly top-category breakdown for {month_key} "
                f"in the current summary for {self._scope_label(summary)}."
            )
        annual_categories = (
            annual.get("top_expense_categories_year")
            if isinstance(annual.get("top_expense_categories_year"), list)
            else []
        )
        if annual_categories and isinstance(annual_categories[0], dict):
            top = annual_categories[0]
            category = clamp_str(top.get("category", ""), 64)
            amount = float(top.get("amount", 0) or 0)
            if category and amount > 0:
                return (
                    f"In the yearly summary for {self._scope_label(summary)}, "
                    f"the top category is {category} at about ${amount:.0f}."
                )
        rolling_categories = (
            summary.get("top_expense_categories")
            if isinstance(summary.get("top_expense_categories"), list)
            else []
        )
        if rolling_categories and isinstance(rolling_categories[0], dict):
            top = rolling_categories[0]
            category = clamp_str(top.get("category", ""), 64)
            amount = float(top.get("amount", 0) or 0)
            if category and amount > 0:
                return (
                    f"In the last 30 days for {self._scope_label(summary)}, "
                    f"the top category is {category} at about ${amount:.0f}."
                )
        return ""

    def _recent_transactions_anchor(self, summary, max_items=5):
        """Build deterministic recent-transactions summary from validated snapshot."""
        if not isinstance(summary, dict):
            return ""
        recent = summary.get("recent_transactions")
        if not isinstance(recent, list) or not recent:
            return ""
        rows = []
        for item in recent[:max_items]:
            if not isinstance(item, dict):
                continue
            date = clamp_str(item.get("date", ""), 16)
            name = clamp_str(item.get("name", ""), 64) or "Transaction"
            amount = float(item.get("amount", 0) or 0)
            if not date:
                continue
            rows.append((date, name, amount))
        if not rows:
            return ""

        text = "; ".join(f"{d} {n} {describe_plaid_amount(a)}" for d, n, a in rows)
        return f"Most recent transactions for {self._scope_label(summary)}: {text}."

    def _build_clarification_question(self, intent, query_spec):
        """Generate clarification that asks for missing signal, not generic period repeatedly."""
        spec = query_spec if isinstance(query_spec, dict) else {}
        period_type = clamp_str(spec.get("period_type", ""), 24) or "unknown"
        period_key = clamp_str(spec.get("period_key", ""), 64)

        if intent == "compare_periods":
            return "Please provide two periods to compare, for example 2026-03 vs 2026-04."

        if period_type != "unknown" and period_key:
            if intent in {"general", "explain", "planning", "what_if"}:
                return (
                    f"I can use {period_key}. Do you want total spending, top category, "
                    "or an explanation/advice?"
                )
            return (
                f"I can use {period_key}. Please confirm the metric you want "
                "(expenses, income, or net)."
            )

        return "Which time period should I use (for example, 2026-03 or last 30 days)?"

    def _category_spending_anchor(self, summary, query_spec=None):
        """Build deterministic category-spending answer for provided category + period."""
        if not isinstance(summary, dict):
            return ""
        spec = query_spec if isinstance(query_spec, dict) else {}
        category = clamp_str(spec.get("category", ""), 64)
        if not category:
            return ""
        period_type = clamp_str(spec.get("period_type", ""), 24)
        period_key = clamp_str(spec.get("period_key", ""), 64)
        month_index = (
            summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
        )
        annual = (
            summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
        )
        annual_top = (
            annual.get("top_expense_categories_year")
            if isinstance(annual.get("top_expense_categories_year"), list)
            else []
        )
        rolling_top = (
            summary.get("top_expense_categories")
            if isinstance(summary.get("top_expense_categories"), list)
            else []
        )

        def _norm(value):
            return re.sub(r"\s+", " ", (value or "").strip().lower())

        def _find_amount(rows):
            for row in rows:
                if not isinstance(row, dict):
                    continue
                name = clamp_str(row.get("category", ""), 64)
                if _norm(name) != _norm(category):
                    continue
                return float(row.get("amount", 0) or 0)
            return 0.0

        if period_type == "month" and period_key:
            month_row = month_index.get(period_key)
            if isinstance(month_row, dict):
                top = month_row.get("top_category")
                if isinstance(top, dict):
                    name = clamp_str(top.get("name", ""), 64)
                    amount = float(top.get("amount", 0) or 0)
                    if _norm(name) == _norm(category) and amount > 0:
                        return (
                            f"For {period_key}, {category} spending for {self._scope_label(summary)} "
                            f"is about ${amount:.0f}."
                        )
            return (
                f"I do not see a month-level category amount for {category} in {period_key} "
                f"for {self._scope_label(summary)}."
            )

        if period_type == "year" and period_key:
            amount = _find_amount(annual_top)
            if amount > 0:
                return (
                    f"For {period_key}, {category} spending for {self._scope_label(summary)} "
                    f"is about ${amount:.0f}."
                )
            return (
                f"I do not see a yearly category amount for {category} in {period_key} "
                f"for {self._scope_label(summary)}."
            )

        amount = _find_amount(rolling_top)
        if amount > 0:
            return (
                f"In the last 30 days, {category} spending for {self._scope_label(summary)} "
                f"is about ${amount:.0f}."
            )
        return f"I do not see a category amount for {category} in the current summary."

    def _amount_supplement(self, summary, message):
        """Provide a best-effort amount fallback from available summary scopes."""
        if not isinstance(summary, dict):
            return ""

        mode = self._timeframe_mode(message)
        annual = (
            summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
        )
        annual_categories = (
            annual.get("top_expense_categories_year")
            if isinstance(annual.get("top_expense_categories_year"), list)
            else []
        )
        rolling_categories = (
            summary.get("top_expense_categories")
            if isinstance(summary.get("top_expense_categories"), list)
            else []
        )

        prefer_annual = mode == "annual_year"
        source = annual_categories if prefer_annual else rolling_categories
        source_name = "yearly summary" if prefer_annual else "last 30 days summary"

        if not source and prefer_annual:
            source = rolling_categories
            source_name = "last 30 days summary"
        if not source:
            return ""

        top = source[0] if isinstance(source[0], dict) else None
        if not isinstance(top, dict):
            return ""
        name = clamp_str(top.get("category", ""), 64)
        amount = float(top.get("amount", 0) or 0)
        if not name or amount <= 0:
            return ""
        return f"In the available {source_name} for {self._scope_label(summary)}, {name} is about ${amount:.0f}."

    def _amount_anchor(self, summary, message, query_spec=None):
        """Always provide one authoritative amount sentence for requested window."""
        if not isinstance(summary, dict):
            return ""
        spec = query_spec if isinstance(query_spec, dict) else {}
        spec_type = clamp_str(spec.get("period_type", ""), 24)
        spec_key = clamp_str(spec.get("period_key", ""), 64)
        metric = clamp_str(spec.get("metric", ""), 24) or "expenses"
        metric = "income" if metric == "income" else "expenses"
        metric_label = "income" if metric == "income" else "expenses"
        mode = self._timeframe_mode(message)
        month_index = (
            summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
        )
        day_index_recent = (
            summary.get("day_index_recent")
            if isinstance(summary.get("day_index_recent"), dict)
            else {}
        )
        month_day_index = (
            summary.get("month_day_index")
            if isinstance(summary.get("month_day_index"), dict)
            else {}
        )
        annual = (
            summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
        )
        annual_year = int(annual.get("year", 0) or 0)
        year_index = (
            summary.get("year_index") if isinstance(summary.get("year_index"), dict) else {}
        )
        annual_totals = annual.get("totals") if isinstance(annual.get("totals"), dict) else {}
        annual_categories = (
            annual.get("top_expense_categories_year")
            if isinstance(annual.get("top_expense_categories_year"), list)
            else []
        )
        daily_expense_totals = (
            annual.get("daily_expense_totals")
            if isinstance(annual.get("daily_expense_totals"), list)
            else []
        )
        rolling_categories = (
            summary.get("top_expense_categories")
            if isinstance(summary.get("top_expense_categories"), list)
            else []
        )

        if spec_type == "month_range":
            month_keys = [
                clamp_str(x.strip(), 16) for x in spec_key.split(",") if clamp_str(x.strip(), 16)
            ]
            if len(month_keys) >= 2:
                total = 0.0
                for key in month_keys:
                    row = month_index.get(key)
                    if not isinstance(row, dict):
                        return ""
                    total += float(row.get(metric, 0) or 0)
                return (
                    f"For {month_keys[0]} to {month_keys[-1]}, total {metric_label} for {self._scope_label(summary)} "
                    f"are about ${total:.0f}."
                )
        if spec_type == "rolling_days":
            match = re.match(r"^rolling_(\d{1,3})d$", spec_key)
            if match:
                days = max(1, min(365, int(match.group(1))))
                today = date_cls.today()
                cutoff = date_cls.fromordinal(today.toordinal() - (days - 1))
                total = 0.0
                matched = 0
                for day, item in day_index_recent.items():
                    if not isinstance(item, dict):
                        continue
                    try:
                        parsed = date_cls.fromisoformat(day)
                    except Exception:
                        continue
                    if parsed < cutoff or parsed > today:
                        continue
                    total += float(item.get(metric, 0) or 0)
                    matched += 1
                if matched > 0:
                    coverage_ratio = matched / max(1, days)
                    coverage_note = (
                        " (based on limited recorded days in this window)"
                        if coverage_ratio < 0.4
                        else ""
                    )
                    return (
                        f"For the last {days} days, total recorded {metric_label} for {self._scope_label(summary)} "
                        f"are about ${total:.0f}{coverage_note}."
                    )
                return (
                    f"I do not see enough recent daily data for the last {days} days "
                    f"for {self._scope_label(summary)}."
                )
        if spec_type == "year" and spec_key:
            row = year_index.get(spec_key)
            if isinstance(row, dict):
                amount = float(row.get(metric, 0) or 0)
                return (
                    f"For {spec_key}, total recorded {metric_label} for {self._scope_label(summary)} "
                    f"are about ${amount:.0f}."
                )
            if str(annual_year) == spec_key:
                annual_field = "income_year" if metric == "income" else "expenses_year"
                amount = float(annual_totals.get(annual_field, 0) or 0)
                return (
                    f"For {spec_key}, total recorded {metric_label} for {self._scope_label(summary)} "
                    f"are about ${amount:.0f}."
                )
            return (
                f"I do not see recorded {metric_label} for {spec_key} in the current summary "
                f"for {self._scope_label(summary)}."
            )

        date_key = (
            spec_key
            if spec_type == "day"
            else self._extract_specific_date_key(message, annual_year)
        )
        if date_key:
            v2_day = day_index_recent.get(date_key)
            if isinstance(v2_day, dict):
                amount = float(v2_day.get(metric, 0) or 0)
                return (
                    f"For {date_key}, recorded {metric_label} for {self._scope_label(summary)} "
                    f"are about ${amount:.0f}."
                )
            month_key_for_day = date_key[:7]
            rows = month_day_index.get(month_key_for_day)
            if isinstance(rows, list):
                for row in rows:
                    if not isinstance(row, dict):
                        continue
                    if clamp_str(row.get("date", ""), 16) != date_key:
                        continue
                    amount = float(row.get(metric, 0) or 0)
                    return (
                        f"For {date_key}, recorded {metric_label} for {self._scope_label(summary)} "
                        f"are about ${amount:.0f}."
                    )
            for item in daily_expense_totals:
                if metric != "expenses":
                    break
                if not isinstance(item, dict):
                    continue
                if clamp_str(item.get("date", ""), 16) != date_key:
                    continue
                amount = float(item.get("amount", 0) or 0)
                return f"For {date_key}, recorded expenses for {self._scope_label(summary)} are about ${amount:.0f}."
            return f"I do not see recorded {metric_label} for {date_key} in the current summary for {self._scope_label(summary)}."

        month_key = (
            spec_key
            if spec_type == "month"
            else self._extract_specific_month_key(message, annual_year)
        )
        if month_key:
            v2_month = month_index.get(month_key)
            if isinstance(v2_month, dict):
                month_amount = float(v2_month.get(metric, 0) or 0)
                if metric == "expenses":
                    top = v2_month.get("top_category")
                    if isinstance(top, dict):
                        top_name = clamp_str(top.get("name", ""), 64)
                        top_amount = float(top.get("amount", 0) or 0)
                        if top_name and top_amount > 0:
                            return (
                                f"For {month_key}, total expenses for {self._scope_label(summary)} "
                                f"are about ${month_amount:.0f}; top category is {top_name} at about ${top_amount:.0f}."
                            )
                return (
                    f"For {month_key}, total {metric_label} for {self._scope_label(summary)} "
                    f"are about ${month_amount:.0f}."
                )
            return (
                f"I do not see recorded {metric_label} for {month_key} in the current summary "
                f"for {self._scope_label(summary)}."
            )

        if mode == "selected_month":
            this_month_key = date_cls.today().strftime("%Y-%m")
            this_month_row = month_index.get(this_month_key)
            if isinstance(this_month_row, dict):
                month_expenses = float(this_month_row.get("expenses", 0) or 0)
                month_expense_tx = int(this_month_row.get("expense_tx_count", 0) or 0)
                if month_expenses <= 0 and month_expense_tx <= 0:
                    return (
                        f"I do not see recorded expenses for {this_month_key} in the "
                        f"current summary for {self._scope_label(summary)}."
                    )
                return (
                    f"For {this_month_key}, total expenses for {self._scope_label(summary)} "
                    f"are about ${month_expenses:.0f}."
                )
            return (
                f"I do not see recorded expenses for {this_month_key} in the current "
                f"summary for {self._scope_label(summary)}."
            )

        if self._asks_month_overview(message):
            rankings = summary.get("rankings") if isinstance(summary.get("rankings"), dict) else {}
            top_months = (
                rankings.get("highest_spending_months")
                if isinstance(rankings.get("highest_spending_months"), list)
                else []
            )
            if top_months and isinstance(top_months[0], dict):
                month = clamp_str(top_months[0].get("month", ""), 16)
                expenses = float(top_months[0].get("expenses", 0) or 0)
                if month and expenses > 0:
                    return (
                        f"The highest spending month for {self._scope_label(summary)} "
                        f"is {month} at about ${expenses:.0f}."
                    )

        if mode == "rolling_30d":
            source = rolling_categories
            label = "last 30 days"
        elif mode == "annual_year":
            expenses_year = float(annual_totals.get("expenses_year", 0) or 0)
            if annual_year > 0 and expenses_year > 0:
                return (
                    f"For {annual_year}, total recorded expenses for "
                    f"{self._scope_label(summary)} are about ${expenses_year:.0f}."
                )
            source = annual_categories if annual_categories else rolling_categories
            label = "yearly summary" if annual_categories else "last 30 days"
        else:
            return ""

        if not source or not isinstance(source[0], dict):
            return ""
        top = source[0]
        name = clamp_str(top.get("category", ""), 64)
        amount = float(top.get("amount", 0) or 0)
        if not name or amount <= 0:
            return ""
        return f"For {label} in {self._scope_label(summary)}, the top category amount is {name} at about ${amount:.0f}."

    def _resolve_response_mode(self, intent):
        """Map intent into execution mode for deterministic/LLM routing."""
        deterministic_intents = {
            "top_category_lookup",
            "recent_transactions",
        }
        if intent in deterministic_intents:
            return "deterministic"
        if intent == "amount_lookup":
            return "hybrid"
        if intent == "compare_periods":
            return "hybrid"
        return "llm"

    def _is_factual_intent(self, intent):
        return intent in FACTUAL_INTENTS

    def _should_use_deterministic(self, intent, query_spec):
        """Strict deterministic gate: only obvious factual asks."""
        if intent == "recent_transactions":
            return True
        if intent == "top_category_lookup":
            return True
        if intent != "amount_lookup" or not isinstance(query_spec, dict):
            return False
        metric = clamp_str(query_spec.get("metric", ""), 24)
        period_type = clamp_str(query_spec.get("period_type", ""), 24)
        period_key = clamp_str(query_spec.get("period_key", ""), 64)
        if metric != "expenses":
            return False
        if period_type == "rolling_30d" and period_key == "rolling_30d":
            return True
        if period_type == "rolling_days" and re.match(r"^rolling_\d{1,3}d$", period_key):
            return True
        if period_type == "month" and bool(period_key):
            return True
        if period_type == "year" and bool(period_key):
            return True
        return False

    def _sanitize_response_mode(self, model_mode, intent, query_spec, fallback_mode):
        """Combine model-selected mode with local safety checks."""
        allowed = {"deterministic", "llm", "hybrid", "clarification"}
        mode = (
            model_mode if isinstance(model_mode, str) and model_mode in allowed else fallback_mode
        )
        query_complete = self._is_query_complete(query_spec, intent)
        if mode == "deterministic" and not query_complete:
            return "clarification"
        if mode == "llm" and intent in FACTUAL_INTENTS and query_complete:
            return "hybrid"
        return mode

    def _merge_query_spec(self, base_spec, entities):
        """Merge model entities into query spec, preferring explicit non-unknown values."""
        merged = dict(base_spec or {})
        if not isinstance(entities, dict):
            return merged
        for key in (
            "metric",
            "period_type",
            "period_key",
            "reason_mode",
            "scope",
            "intent",
            "category",
            "compare_to",
        ):
            value = entities.get(key)
            if not isinstance(value, str):
                continue
            cleaned = value.strip()
            if not cleaned or cleaned == "unknown":
                continue
            merged[key] = cleaned
        return merged

    def _is_query_complete(self, query_spec, intent):
        """Check whether query spec has enough period context for factual execution."""
        if not isinstance(query_spec, dict):
            return False
        if intent not in FACTUAL_INTENTS:
            return True
        period_type = clamp_str(query_spec.get("period_type", ""), 24) or "unknown"
        period_key = clamp_str(query_spec.get("period_key", ""), 64)
        if period_type == "month_range" and intent in {"amount_lookup", "top_category_lookup"}:
            keys = [x.strip() for x in period_key.split(",") if x.strip()]
            return len(keys) >= 2
        if (
            period_type == "month_range"
            and intent == "compare_periods"
            and self._router_v2_enabled()
        ):
            keys = [x.strip() for x in period_key.split(",") if x.strip()]
            return len(keys) >= 2
        if intent == "compare_periods":
            left, right = self._extract_compare_periods(period_key)
            return bool(left and right)
        return period_type != "unknown" and bool(period_key)

    def _extract_compare_periods(self, period_key):
        """Parse compare period key into left/right period tokens."""
        if not isinstance(period_key, str):
            return "", ""
        value = period_key.strip()
        if not value:
            return "", ""
        tokens = [x.strip() for x in re.split(r"[,\|]", value) if x.strip()]
        if len(tokens) >= 2:
            return tokens[0], tokens[1]
        match = re.match(r"(.+?)\s+vs\s+(.+)", value, re.IGNORECASE)
        if match:
            return match.group(1).strip(), match.group(2).strip()
        return "", ""

    def _extract_compare_periods_from_message(self, message):
        """Fallback parser for compare period pairs from raw message."""
        text = clamp_str(message or "", 4000).lower()
        month_keys = re.findall(r"\b20\d{2}-\d{2}\b", text)
        if len(month_keys) >= 2:
            return month_keys[0], month_keys[1]
        years = re.findall(r"\b20\d{2}\b", text)
        if len(years) >= 2:
            return years[0], years[1]
        month_names = sorted({num for _, num in month_mentions(text)})
        year = re.search(r"\b20\d{2}\b", text)
        if len(month_names) >= 2 and year:
            y = int(year.group(0))
            return f"{y}-{month_names[0]:02d}", f"{y}-{month_names[1]:02d}"
        return "", ""

    def _compare_periods_anchor(self, summary, query_spec, message):
        """Deterministic period comparison for month-vs-month and year-vs-year."""
        if not isinstance(summary, dict):
            return "", ["summary_data_for_period"]
        period_key = clamp_str((query_spec or {}).get("period_key", ""), 64)
        left, right = self._extract_compare_periods(period_key)
        if not (left and right):
            left, right = self._extract_compare_periods_from_message(message)
        if not (left and right):
            return "", ["period"]
        month_index = (
            summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
        )
        year_index = (
            summary.get("year_index") if isinstance(summary.get("year_index"), dict) else {}
        )

        def _lookup(period):
            if re.match(r"^20\d{2}-\d{2}$", period):
                row = month_index.get(period)
                if isinstance(row, dict):
                    return float(row.get("expenses", 0) or 0), "month"
                return None, "month"
            if re.match(r"^20\d{2}$", period):
                row = year_index.get(period)
                if isinstance(row, dict):
                    return float(row.get("expenses", 0) or 0), "year"
                annual = (
                    summary.get("annual_summary")
                    if isinstance(summary.get("annual_summary"), dict)
                    else {}
                )
                annual_year = str(int(annual.get("year", 0) or 0))
                if annual_year == period:
                    totals = annual.get("totals") if isinstance(annual.get("totals"), dict) else {}
                    return float(totals.get("expenses_year", 0) or 0), "year"
                return None, "year"
            return None, "unknown"

        left_amount, left_kind = _lookup(left)
        right_amount, right_kind = _lookup(right)
        missing = []
        if left_amount is None:
            missing.append(f"summary_data_for_period:{left}")
        if right_amount is None:
            missing.append(f"summary_data_for_period:{right}")
        if missing:
            return "", missing
        if left_kind != right_kind:
            return "", ["period_type_mismatch"]

        diff = right_amount - left_amount
        pct = 0.0 if left_amount == 0 else (diff / left_amount) * 100
        anchor = (
            f"Comparing {left} vs {right} for {self._scope_label(summary)}: "
            f"${left_amount:.0f} vs ${right_amount:.0f}, change ${diff:.0f} ({pct:.1f}%)."
        )
        return anchor, []

    def _extract_spending_change_query_spec(self, message, summary):
        """Normalize natural-language 'why did spending change' asks into one canonical query."""
        text = clamp_str(message or "", 4000).lower()
        if not text:
            return None
        has_spending = (
            ("spending" in text)
            or ("expenses" in text)
            or bool(re.search(r"\bspend(ing)?\b", text))
        )
        if not has_spending:
            return None
        has_change_signal = any(
            token in text
            for token in (
                "increase",
                "increased",
                "up",
                "grew",
                "grow",
                "rise",
                "rose",
                "changed",
                "change",
                "higher",
                "lower",
                "decrease",
                "decreased",
                "down",
            )
        )
        has_causal_signal = any(
            token in text
            for token in (
                "why",
                "caused",
                "cause",
                "what changed",
                "what drove",
                "how come",
                "reason",
            )
        )
        if not (has_change_signal or has_causal_signal):
            return None
        if "last month" not in text:
            return None

        period_key = self._previous_month_key(summary)
        if not period_key:
            return None
        if not re.match(r"^20\d{2}-\d{2}$", period_key):
            return None

        return {
            "intent": "explain",
            "metric": "expenses",
            "period_type": "month",
            "period_key": period_key,
            "reason_mode": "spending_change",
            "scope": self._scope_key(summary),
        }

    def _spending_change_anchor(self, summary, query_spec):
        if not isinstance(summary, dict):
            return ""
        month_index = (
            summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
        )
        if not month_index:
            return ""
        spec = query_spec if isinstance(query_spec, dict) else {}
        period_key = clamp_str(spec.get("period_key", ""), 16)
        target_month_key = period_key if re.match(r"^20\d{2}-\d{2}$", period_key) else ""
        if not target_month_key:
            return ""
        try:
            y, m = target_month_key.split("-")
            y_i = int(y)
            m_i = int(m)
            prev_key = f"{y_i - 1}-12" if m_i == 1 else f"{y_i}-{m_i - 1:02d}"
        except Exception:
            return ""
        last_row = month_index.get(target_month_key)
        prev_row = month_index.get(prev_key)
        if not isinstance(last_row, dict) or not isinstance(prev_row, dict):
            return ""
        last_exp = float(last_row.get("expenses", 0) or 0)
        prev_exp = float(prev_row.get("expenses", 0) or 0)
        delta = last_exp - prev_exp
        if abs(delta) < 1:
            return (
                f"Your spending in {target_month_key} was roughly flat versus {prev_key} "
                f"for {self._scope_label(summary)} (${last_exp:.0f} vs ${prev_exp:.0f})."
            )
        direction = "increased" if delta > 0 else "decreased"
        lead = (
            f"Your spending in {target_month_key} {direction} versus {prev_key} "
            f"for {self._scope_label(summary)} by about ${abs(delta):.0f} "
            f"(${last_exp:.0f} vs ${prev_exp:.0f})."
        )
        last_top = (
            last_row.get("top_category") if isinstance(last_row.get("top_category"), dict) else {}
        )
        prev_top = (
            prev_row.get("top_category") if isinstance(prev_row.get("top_category"), dict) else {}
        )
        last_top_name = clamp_str(last_top.get("name", ""), 64)
        prev_top_name = clamp_str(prev_top.get("name", ""), 64)
        last_top_amt = float(last_top.get("amount", 0) or 0)
        prev_top_amt = float(prev_top.get("amount", 0) or 0)
        if last_top_name and last_top_amt > 0:
            if prev_top_name == last_top_name and prev_top_amt > 0:
                return (
                    f"{lead} The largest non-transfer category was {last_top_name}, "
                    f"rising from about ${prev_top_amt:.0f} to ${last_top_amt:.0f}."
                )
            return (
                f"{lead} The largest non-transfer category in {target_month_key} was "
                f"{last_top_name} at about ${last_top_amt:.0f}."
            )
        return lead

    def _should_clarify(self, intent_confidence, needs_clarification, query_spec, intent):
        """Calibrated clarification gate based on confidence and query completeness."""
        query_complete = self._is_query_complete(query_spec, intent)
        if intent not in FACTUAL_INTENTS:
            return intent_confidence < self.MID_CONFIDENCE_THRESHOLD and needs_clarification
        if intent_confidence >= self.HIGH_CONFIDENCE_THRESHOLD:
            return not query_complete and needs_clarification
        if intent_confidence >= self.MID_CONFIDENCE_THRESHOLD:
            return not query_complete
        return True

    def _debug_route_log(
        self,
        *,
        intent_source,
        intent,
        intent_confidence,
        mode,
        answer_source,
        needs_clarification,
        missing_fields,
        query_spec,
        message,
        model_response_mode="",
        fallback_mode="",
    ):
        """Emit lightweight routing diagnostics without logging full prompt text."""
        period_type = clamp_str((query_spec or {}).get("period_type", ""), 24) or "unknown"
        period_key = clamp_str((query_spec or {}).get("period_key", ""), 64)
        rm_model = clamp_str(model_response_mode or "", 24) or "none"
        rm_intent = clamp_str(fallback_mode or "", 24) or "none"
        rm_final = clamp_str(mode or "", 24) or "none"
        mode_effective = (
            "deterministic" if str(answer_source).startswith("deterministic") else rm_final
        )
        mode_overridden = mode_effective != rm_final
        print(
            "[ai.chat.route] "
            f"intent_source={intent_source} intent={intent} confidence={intent_confidence:.2f} "
            f"response_mode_model={rm_model} response_mode_from_intent={rm_intent} response_mode_final={rm_final} "
            f"response_mode_effective={mode_effective} mode_overridden={str(mode_overridden).lower()} "
            f"answer_source={answer_source} needs_clarification={bool(needs_clarification)} "
            f"missing_fields={','.join(missing_fields or []) or 'none'} period_type={period_type} "
            f"period_key={period_key or 'none'} prompt_len={len(message or '')}"
        )

    _OTHER_CURRENCY_RE = re.compile(
        r"\b(euros?|eur|pounds? sterling|gbp|yen|jpy|rmb|yuan|cny|cad|aud)\b|[€£¥]"
        r"|人民币|欧元|日元|英镑|加元|澳元"
    )

    _QUESTION_SPLIT_RE = re.compile(r"\?+|[;\n]|\s+(?:also|and also|plus)\s+", re.IGNORECASE)

    def _split_questions(self, prompt):
        parts = []
        for part in self._QUESTION_SPLIT_RE.split(prompt or ""):
            part = re.sub(r"^\s*(and|also|plus)\b", "", part.strip(), flags=re.IGNORECASE)
            if len(part.split()) >= 2:
                parts.append(part.strip(" ,."))
        return parts

    def _multi_question_response(self, payload):
        """ "How much did I spend? Also what's my income? And my top category?" gets one
        answer per question, when every part has a deterministic answer."""
        parts = self._split_questions(clamp_str((payload or {}).get("prompt", ""), 4000))
        if not 2 <= len(parts) <= 4 or not self._router_v2_enabled():
            return None
        summary = sanitize_spending_summary((payload or {}).get("spending_summary"))
        if summary is None:
            return None
        history = sanitize_history((payload or {}).get("history"), max_turns=6)
        results = []
        for part in parts:
            parsed = parse_query_v2(part, summary, history=history)
            plan = build_execution_plan_v2(parsed, summary)
            if plan.mode != "deterministic":
                return None
            result = execute_plan_v2(plan, parsed, summary, self._scope_label(summary))
            result = validate_v2_response(plan, parsed, result)
            if not isinstance(result, dict) or not result.get("reply"):
                return None
            results.append(result)
        totals = summary.get("totals") if isinstance(summary.get("totals"), dict) else {}
        return build_chat_response(
            reply=clamp_str(" ".join(r["reply"] for r in results), 2500),
            insights=[x for r in results for x in r.get("insights", [])][:3],
            actions=[x for r in results for x in r.get("actions", [])][:3],
            citations=["deterministic_anchor_v2"],
            intent="multi_question",
            intent_confidence=0.95,
            intent_candidates=["multi_question"],
            intent_source="rule",
            needs_clarification=False,
            context_source="deterministic_anchor_v2",
            used_summary=True,
            tx_count_30d=int(totals.get("tx_count_30d", 0) or 0),
            summary_empty=False,
            answer_source="deterministic",
            facts_used=[x for r in results for x in r.get("facts_used", [])],
            period_resolved=", ".join(r.get("period_resolved", "") for r in results),
        )

    # "on my credit card", "my checking account", "card ending 4191": an account named in
    # the question. The chat only gets the account picked in the app's scope menu.
    _ACCOUNT_MENTION_RE = re.compile(
        r"(?:\b(on|with|from|in|using|for|of|to)\s+)?\b(?:my|the|this)\s+"
        r"(credit card|card|checking account|checking|savings account|debit card|bank account|"
        r"(?:chase|amex|american express|citi|discover|capital one|wells fargo|bank of america)"
        r"(?: [a-z]+)?(?: account| card)?)\b"
        r"|\b(?:card|account) ending(?: in)? (\d{4})\b",
        re.IGNORECASE,
    )

    _CARD_PAYMENT_ASK_RE = re.compile(
        r"\b(pay|paid|paying|payment|payments)\b.{0,30}\b(credit card|card|cards)\b|"
        r"\bcard payments?\b",
        re.IGNORECASE,
    )

    def _account_scope_note(self, prompt, summary):
        """(question without the account words, note) when the question names an account.
        The note says which account the answer covers and how to switch."""
        match = self._ACCOUNT_MENTION_RE.search(prompt or "")
        if match and re.search(
            r"\bhow much (money )?is (in|on|left in)\b|\bbalance\b|\bhow much do i (have|owe)\b|"
            r"\bwhat(?:'s| is) in\b",
            prompt or "",
            re.IGNORECASE,
        ):
            return prompt, ""  # "how much is in my savings account": the balance answer covers it
        if match and re.search(
            r"^\s*(please )?(transfer|move|send|wire|deposit|withdraw)\b|"
            r"\b(can|could|would|will) you (please )?(transfer|move|send|wire|pay|deposit|withdraw)\b",
            prompt or "",
            re.IGNORECASE,
        ):
            return prompt, ""  # a request to move money: the refusal covers every account
        if not match or self._CARD_PAYMENT_ASK_RE.search(prompt or ""):
            # "how much did I pay toward my credit card" is about the payments themselves.
            return prompt, ""
        named = (match.group(2) or f"account ending {match.group(3)}").lower()
        # Keep "my" when nothing came before it: "what's my card spending" -> "what's my spending".
        stripped = self._ACCOUNT_MENTION_RE.sub(
            lambda m: "" if m.group(1) or m.group(3) else "my", prompt, count=1
        )
        stripped = re.sub(r"\s+", " ", stripped).strip()
        summary = summary if isinstance(summary, dict) else {}
        label = clamp_str(summary.get("scope_label", ""), 64)
        if summary.get("scope") != "single_account":
            return stripped, (
                f"This is for all your accounts together (to see only your {named}, pick it in "
                "the Account scope menu above the chat)."
            )
        bank = re.search(r"checking|savings|debit|bank account", named)
        card = not bank and re.search(r"\bcard\b|amex|american express|discover", named)
        if match.group(3):
            same = match.group(3) in label
        elif bank or card:
            same = bool(card) == credit_card_scope(summary)
        else:
            same = named.split()[0] in label.lower()  # a bank name: "my chase account"
        if same:
            return stripped, ""
        return stripped, (
            f"This only covers {label or 'the selected account'}, the account picked in the "
            f"Account scope menu (pick your {named} there to see it)."
        )

    def handle_chat(self, payload, user_id=None):
        """Chat entry point: answer, then flag amounts asked in another currency and which
        account an answer covers when the question names one."""
        payload = dict(payload or {})
        original = clamp_str(payload.get("prompt", ""), 4000)
        stripped, scope_note = self._account_scope_note(
            original, sanitize_spending_summary(payload.get("spending_summary"))
        )
        if scope_note or stripped != original:
            payload["prompt"] = stripped or original
        response = self._multi_question_response(payload) or self._handle_chat(
            payload, user_id=user_id
        )
        if isinstance(response, dict):
            note = self._coverage_note(
                original, response, sanitize_spending_summary(payload.get("spending_summary"))
            )
            if note:
                reply = str(response.get("reply", "") or "")
                response["reply"] = clamp_str(f"{reply} {note}".strip(), 2500)
        if isinstance(response, dict) and scope_note:
            # Lead with it, so the numbers aren't read as the account the user named.
            reply = str(response.get("reply", "") or "")
            response["reply"] = clamp_str(f"{scope_note} {reply}".strip(), 2500)
        prompt = original.lower()
        if isinstance(response, dict) and self._OTHER_CURRENCY_RE.search(prompt):
            note = "Amounts are in US dollars; I can't convert currencies."
            reply = str(response.get("reply", "") or "")
            if note not in reply:
                response["reply"] = clamp_str(f"{reply} {note}".strip(), 2500)
        if isinstance(response, dict) and isinstance(response.get("reply"), str):
            response["reply"] = group_dollar_amounts(response["reply"])
        return response

    _ASKS_INCOME_RE = re.compile(
        r"\b(income|earn|earned|earning|earnings|salary|paycheck|money (came )?in)\b"
    )
    _ASKS_NET_RE = re.compile(
        r"\b(net|cash flow|make money|made money|in the green|in the red|come out ahead|"
        r"left (with|over)|have left|had left)\b"
    )
    _ASKS_EXTREME_RE = re.compile(
        r"\b(which|what) (month|week|quarter|season)\b.*\b(most|least|highest|lowest)\b|"
        r"\bwhen (did|was|were)\b.*\b(most|least|highest|lowest|biggest|smallest)\b|"
        r"\b(most|least) i (ve |have )?(spent|earned|made) in (one|a|a single) month\b|"
        r"\bin (one|a single) month\b|"
        r"\b(highest|lowest|biggest|smallest|most expensive|cheapest|priciest)[ -]spending "
        r"(month|week|day|quarter)\b|"
        r"\bthe (most|least) i (ve |have )?(ever )?(spent|earned|made)\b.*\bin (a|one|any) month\b"
    )
    # "top category is Food" in a plain monthly total doesn't name the highest month
    _ANSWERED_EXTREME_RE = re.compile(
        r"\b(highest|lowest|biggest|smallest|cheapest|priciest|most expensive)\b|"
        r"\bthe (most|least)\b|\b(most|least) (in|on|was|of)\b",
        re.IGNORECASE,
    )
    _ASKS_CHANGE_RE = re.compile(
        r"^(did|has|have|was|were) my\b.*\b(drop|dropped|go up|go down|went up|went down|fall|fell|"
        r"rise|rose|increase|increased|decrease|decreased|dip|jump|climb)\b"
    )
    _ANSWERED_CHANGE_RE = re.compile(
        r"\bvs\b|\b(higher|lower|more|less|up|down) (than|from)\b|\bchanged?\b|\bwent (up|down)\b|"
        r"\bgoing (up|down)\b|\bflat\b|\b(rose|fell|dropped|increased|decreased)\b",
        re.IGNORECASE,
    )
    _ASKS_THRESHOLD_RE = re.compile(
        r"^(did|was|were|is|am|have|has|will|do)\b.*\b(over|under|more than|less than|above|"
        r"below|at least|at most)\s+\$?\s?\d"
    )
    _ANSWERED_THRESHOLD_RE = re.compile(
        r"^(Yes|No|Probably|Not yet)\b|\b(over|under|above|below) \$\d", re.IGNORECASE
    )
    _ASKS_COUNT_RE = re.compile(r"\bhow many (months|weeks|days)\b")
    _ANSWERED_COUNT_RE = re.compile(r"\b\d+ of (your|the)\b|\bIn \d+ of\b")
    _ASKS_SPEND_RE = re.compile(r"\b(spend|spent|spending|expenses?|cost|costs)\b")
    _ANSWERED_INCOME_RE = re.compile(
        r"income|earned|money into|card payments|not income|paycheck", re.IGNORECASE
    )
    _ANSWERED_NET_RE = re.compile(
        r"net cash flow|saved|savings|earned more|spent more|surplus|behind|ahead|kept|left",
        re.IGNORECASE,
    )
    _EXPLAINED_RE = re.compile(
        r"can't|cannot|doesn't get|don't see|isn't tracked|hasn't happened|haven't happened|"
        r"data starts|not income|first month in your data|I read this as|Chat (only|doesn't)|"
        r"no spending split by category|No category|only has",
        re.IGNORECASE,
    )

    # Plans and what-ifs work from amounts in the question, not from a named period.
    _PLANNING_INTENTS = {
        "what_if",
        "savings_goal",
        "saving_target",
        "affordability",
        "extra_spend",
        "goal_time",
        "budget_suggestion",
        "month_outlook",
    }

    def _coverage_note(self, prompt, response, summary):
        """When a computed answer leaves out a month, category or measure the question
        named, say so instead of quietly answering a different question."""
        if response.get("answer_source") != "deterministic":
            return ""
        missing = self._coverage_gaps(
            prompt, str(response.get("reply", "") or ""), response.get("intent"), summary
        )
        if not missing:
            return ""
        listed = (
            missing[0] if len(missing) == 1 else ", ".join(missing[:-1]) + f" and {missing[-1]}"
        )
        return (
            f"Note: this answer doesn't cover {listed}. If that's what you meant, ask about it "
            "on its own."
        )

    def _coverage_gaps(self, prompt, reply, intent, summary):
        """What the question asked for that the reply doesn't show: a category, a month,
        income or net cash flow, which period was highest, a yes or no, a count."""
        if intent in self._PLANNING_INTENTS:
            return []
        if not reply or self._EXPLAINED_RE.search(reply):
            return []
        text = _normalize(prompt)
        missing = []
        for name in _categories_in(text, summary, include_approx=False):
            if name.lower() not in reply.lower() and name not in missing:
                missing.append(name)
        year = int(resolve_selected_month_key(summary)[:4])
        # "$2000" isn't the year 2000
        asked = [
            k
            for k in _named_month_keys(re.sub(r"\$\s?\d[\d,]*", " ", text), summary)
            if abs(int(k[:4]) - year) <= 1
        ]
        if re.search(r"\blast month\b", text) and "last month" not in reply:
            asked.append(resolve_previous_month_key(summary))
        if re.search(r"\bthis month\b", text) and "this month" not in reply:
            asked.append(resolve_selected_month_key(summary))
        group = []
        season = r"(spring|summer|fall|autumn|winter|q[1-4]|quarter|half)"
        if re.search(
            rf"\b(this|last|the|in|during|over|for|since|from|between) {season}\b|"
            rf"\b{season} (20\d{{2}}|and|vs|or)\b",
            text,
        ) and not re.search(r"\b(spring|summer|fall|autumn|winter|q[1-4]|half)\b", reply, re.I):
            group = [k for k in _month_range_spec(text, summary).split(",") if k]
        shown = set(re.findall(r"\b20\d{2}-\d{2}\b", reply))
        spans = re.findall(r"(20\d{2}-\d{2}) to (20\d{2}-\d{2})", reply)
        since = re.search(r"\b(since|after) [a-z]+\b", text)

        def covered(key):
            if since and any(k >= key for k in shown):
                return True  # "since march": any later month is part of the answer
            return key in shown or any(a <= key <= b for a, b in spans)

        for key in asked:
            if not covered(key) and key not in missing:
                missing.append(key)
        if group and not any(covered(k) for k in group):
            missing.append(f"{group[0]} to {group[-1]}")
        spend = self._ASKS_SPEND_RE.search(text)
        if self._ASKS_INCOME_RE.search(text) and not spend:
            if not self._ANSWERED_INCOME_RE.search(reply):
                missing.append("income")
        elif self._ASKS_NET_RE.search(text) and not self._ANSWERED_NET_RE.search(reply):
            missing.append("net cash flow")
        if self._ASKS_EXTREME_RE.search(text) and not self._ANSWERED_EXTREME_RE.search(reply):
            missing.append("which one was highest or lowest")
        if self._ASKS_THRESHOLD_RE.search(text) and not self._ANSWERED_THRESHOLD_RE.search(reply):
            missing.append("a yes or no")
        if self._ASKS_COUNT_RE.search(text) and not self._ANSWERED_COUNT_RE.search(reply):
            missing.append("how many")
        if self._ASKS_CHANGE_RE.search(text) and not self._ANSWERED_CHANGE_RE.search(reply):
            missing.append("a comparison with an earlier period")
        return missing

    _REWRITE_PROMPT = (
        "Rewrite the user's message as ONE short English question that a budgeting app can "
        "answer from the user's own transaction totals. Use the app's words: spend, income, "
        "net cash flow (income minus spending), a category (Food, Transport, Shopping, "
        "Subscriptions, Entertainment, Health, Housing, Bills & Utilities, Fees & Transfers, "
        "Other) and a period (this month, last month, a month name, this year, last 3 "
        "months).\n"
        "Examples of good rewrites:\n"
        "- How much did I spend on Food this month?\n"
        "- What was my income last month?\n"
        "- What was my net cash flow this month?\n"
        "- Compare my Shopping spending in September vs October.\n"
        "- What are my top 3 categories in September?\n"
        "- Has my Transport spending been increasing?\n"
        "- What is my average monthly Food spending?\n"
        "- Which month did I spend the most on Food?\n"
        "- Did I spend under $1000 on Food in July?\n"
        "- How many months did my income go over $2500?\n"
        "- Is my Food spending normal this month?\n"
        "- Did I earn more than I spent this year?\n"
        "If the message asks for advice, an explanation, an opinion, or anything that is not "
        "a number from their own data, reply exactly: NONE\n"
        "Reply with only the rewritten question.\n\n"
        "User message: {message}\n"
    )

    def _rewrite_question(self, message):
        """Ask the model to restate a question in wording the rules understand. The model
        only rephrases; every number still comes from the data. A wording rewritten before
        is reused from rewrite_cache without a model call."""
        if self.rewrite_cache is not None:
            cached = self.rewrite_cache.get(message)
            if cached:
                return cached
        try:
            raw = self.generate_reply(
                self._REWRITE_PROMPT.format(message=clamp_str(message, 500)),
                generation_config={"temperature": 0.0, "maxOutputTokens": 60},
            )
        except Exception:
            return ""
        text = clamp_str(str(raw or "").strip().strip('"').splitlines()[0] if raw else "", 160)
        text = re.sub(r"^[-*\s]+", "", text).strip()
        if not text or "NONE" in text.upper() or len(text.split()) < 3:
            return ""
        if self.rewrite_cache is not None:
            self.rewrite_cache.put(message, text)
        return text

    def _handle_chat(self, payload, user_id=None):
        """Main chat pipeline: validate input, call model, normalize output."""
        payload = payload or {}
        message = clamp_str(payload.get("prompt", ""), 4000)
        if not message:
            raise ValueError("Missing prompt")

        history = sanitize_history(payload.get("history"), max_turns=6)
        summary = sanitize_spending_summary(payload.get("spending_summary"))
        parsed_v2 = None
        plan_v2 = None
        v2_answers = False
        if self._router_v2_enabled():
            parsed_v2 = parse_query_v2(message, summary, history=history)
            plan_v2 = build_execution_plan_v2(parsed_v2, summary)
            if plan_v2.mode == "deterministic":
                probe = execute_plan_v2(plan_v2, parsed_v2, summary, self._scope_label(summary))
                v2_answers = isinstance(probe, dict) and bool(probe.get("reply"))
        gaps = []
        if v2_answers and not history:
            # The rules answered, but not everything the question asked: let the model
            # restate it and keep whichever answer covers more.
            gaps = self._coverage_gaps(
                message, str(probe.get("reply", "") or ""), parsed_v2.task_type, summary
            )
        # When the deterministic v2 path will answer, skip the model's intent
        # classification: it only adds a model call and seconds of latency.
        rewrite_result = None
        if (
            self._router_v2_enabled()
            and (not v2_answers or gaps)
            and self._rewrite_enabled()
            and not asks_for_advice(message)
            and len(re.findall(r"[A-Za-z]{2,}|[\u4e00-\u9fff]", message)) >= 2
            # A date the rules couldn't read is invalid ("2026-02-30"); don't let the
            # model reinterpret it as something else.
            and not re.search(r"\b20\d{2}-\d{1,2}(-\d{1,2})?\b|\b\d{1,2}/\d{1,2}\b", message)
        ):
            rewritten = self._rewrite_question(message)
            if rewritten:
                parsed_rw = parse_query_v2(rewritten, summary, history=history)
                plan_rw = build_execution_plan_v2(parsed_rw, summary)
                if plan_rw.mode == "deterministic":
                    result_rw = execute_plan_v2(
                        plan_rw, parsed_rw, summary, self._scope_label(summary)
                    )
                    result_rw = validate_v2_response(plan_rw, parsed_rw, result_rw)
                    better = isinstance(result_rw, dict) and bool(result_rw.get("reply"))
                    if better and gaps:
                        better = len(
                            self._coverage_gaps(
                                message, result_rw["reply"], parsed_rw.task_type, summary
                            )
                        ) < len(gaps)
                    if better:
                        # Say how the question was read so a wrong reading is easy to spot.
                        result_rw = dict(result_rw)
                        result_rw["reply"] = clamp_str(
                            f'I read this as "{rewritten}" {result_rw["reply"]}', 2500
                        )
                        parsed_v2, plan_v2, v2_answers = parsed_rw, plan_rw, True
                        rewrite_result = result_rw
        if v2_answers:
            intent_result = self.router.classify_without_llm(message)
        else:
            intent_result = self.router.classify(message, history)
        intent = intent_result.get("intent", "general")
        intent_confidence = float(intent_result.get("intent_confidence", 0.0) or 0.0)
        intent_candidates = intent_result.get("intent_candidates") or [intent]
        intent_source = intent_result.get("intent_source", "rule")
        needs_clarification = bool(intent_result.get("needs_clarification", False))
        model_response_mode = clamp_str(intent_result.get("response_mode", ""), 24)
        entities = (
            intent_result.get("entities") if isinstance(intent_result.get("entities"), dict) else {}
        )
        clarification_question = clamp_str(intent_result.get("clarification_question", ""), 180)
        query_spec = {
            "intent": clamp_str(intent, 24) or "general",
            "metric": "unknown",
            "period_type": "unknown",
            "period_key": "",
            "reason_mode": "",
            "category": "",
            "compare_to": "",
            "scope": self._scope_key(summary),
        }
        query_spec = self._merge_query_spec(query_spec, entities)
        if parsed_v2 is not None and plan_v2 is not None:
            if parsed_v2.task_type != "general":
                query_spec = self._merge_query_spec(query_spec, parsed_v2.to_dict())
                intent = parsed_v2.task_type
                intent_source = "rule"
                if plan_v2.mode == "deterministic":
                    intent_confidence = max(intent_confidence, 0.95)
                    needs_clarification = False
        spending_change_spec = None
        normalized_spending_change = False
        if self._router_v2_enabled():
            spending_change_spec = self._extract_spending_change_query_spec(message, summary)
            normalized_spending_change = bool(spending_change_spec)
            if spending_change_spec:
                query_spec = self._merge_query_spec(spending_change_spec, entities)
                intent = "explain"
                intent_source = "rule"
                intent_confidence = max(intent_confidence, 0.95)
                needs_clarification = False
        should_promote_amount = (
            self._asks_amount(message)
            and intent not in FACTUAL_INTENTS
            and self._is_strict_income_amount_query(message)
        )
        if should_promote_amount:
            fallback_spec = self._extract_query_spec(message, summary, "amount_lookup")
            merged_fallback = self._merge_query_spec(fallback_spec, entities)
            if self._is_query_complete(merged_fallback, "amount_lookup"):
                query_spec = merged_fallback
                intent = "amount_lookup"
                intent_source = "rule"
                intent_confidence = max(intent_confidence, 0.95)
                needs_clarification = False
        elif not self._is_query_complete(query_spec, intent):
            fallback_spec = self._extract_query_spec(message, summary, intent)
            query_spec = self._merge_query_spec(fallback_spec, entities)
        fallback_mode = self._resolve_response_mode(intent)
        mode = self._sanitize_response_mode(model_response_mode, intent, query_spec, fallback_mode)
        summary_meta = (summary or {}).get("totals") or {}
        tx_count_30d = int(summary_meta.get("tx_count_30d", 0) or 0)
        summary_empty = summary is None

        context_source = "frontend_summary"
        used_summary = summary is not None

        # The summary is the request's spending_summary: built on the server from Supabase
        # when the app sends a `context` block (routes/ai_routes.py, ai/server_summary.py),
        # otherwise the one the app sent. ChatService itself never reads the database.
        context_text = self._summary_to_text(summary)
        if summary is None:
            context_source = "frontend_summary_empty"
            used_summary = False
        answer_source = "llm"
        missing_fields = []

        # V2 deterministic plans run before clarification gate to avoid false clarifications.
        if self._router_v2_enabled() and plan_v2 is not None and plan_v2.mode == "deterministic":
            v2_result = rewrite_result or validate_v2_response(
                plan_v2,
                parsed_v2,
                execute_plan_v2(plan_v2, parsed_v2, summary, self._scope_label(summary)),
            )
            if isinstance(v2_result, dict) and v2_result.get("reply"):
                self._debug_route_log(
                    intent_source=intent_source,
                    intent=intent,
                    intent_confidence=intent_confidence,
                    mode=mode,
                    answer_source="deterministic",
                    needs_clarification=False,
                    missing_fields=v2_result.get("missing_fields", []),
                    query_spec=query_spec,
                    message=message,
                    model_response_mode=model_response_mode,
                    fallback_mode=fallback_mode,
                )
                return build_chat_response(
                    reply=v2_result.get("reply", ""),
                    insights=v2_result.get("insights", []),
                    actions=v2_result.get("actions", []),
                    citations=["deterministic_anchor_v2"],
                    intent=intent,
                    intent_confidence=intent_confidence,
                    intent_candidates=intent_candidates,
                    intent_source=intent_source,
                    needs_clarification=False,
                    context_source="deterministic_anchor_v2",
                    used_summary=used_summary,
                    tx_count_30d=tx_count_30d,
                    summary_empty=summary_empty,
                    answer_source="deterministic",
                    resolved_query=query_spec,
                    missing_fields=v2_result.get("missing_fields", []),
                    facts_used=v2_result.get("facts_used", []),
                    period_resolved=v2_result.get("period_resolved", ""),
                )

        should_clarify = self._should_clarify(
            intent_confidence=intent_confidence,
            needs_clarification=needs_clarification,
            query_spec=query_spec,
            intent=intent,
        )
        if mode == "clarification" and not normalized_spending_change:
            should_clarify = True
        if (
            (not normalized_spending_change)
            and should_clarify
            and (intent_source == "llm" or clarification_question or mode != "llm")
        ):
            if not clarification_question:
                clarification_question = self._build_clarification_question(intent, query_spec)
            if intent == "compare_periods":
                missing_fields.append("period_pair")
            elif (query_spec or {}).get("period_type", "unknown") == "unknown":
                missing_fields.append("period")
            else:
                missing_fields.append("intent_or_metric")
            self._debug_route_log(
                intent_source=intent_source,
                intent=intent,
                intent_confidence=intent_confidence,
                mode=mode,
                answer_source="clarification",
                needs_clarification=True,
                missing_fields=missing_fields,
                query_spec=query_spec,
                message=message,
                model_response_mode=model_response_mode,
                fallback_mode=fallback_mode,
            )
            return build_chat_response(
                reply=clarification_question,
                insights=["I need one detail to answer accurately."],
                actions=["Please specify a time period, such as 2026-03."],
                citations=["clarification"],
                intent=intent,
                intent_confidence=intent_confidence,
                intent_candidates=intent_candidates,
                intent_source=intent_source,
                needs_clarification=True,
                context_source=context_source,
                used_summary=used_summary,
                tx_count_30d=tx_count_30d,
                summary_empty=summary_empty,
                answer_source="clarification",
                resolved_query=query_spec,
                missing_fields=missing_fields,
            )

        if AI_ROUTER_V2_ENABLED and plan_v2 is not None and plan_v2.mode == "deterministic":
            v2_result = execute_plan_v2(plan_v2, parsed_v2, summary, self._scope_label(summary))
            v2_result = validate_v2_response(plan_v2, parsed_v2, v2_result)
            if isinstance(v2_result, dict) and v2_result.get("reply"):
                self._debug_route_log(
                    intent_source=intent_source,
                    intent=intent,
                    intent_confidence=intent_confidence,
                    mode=mode,
                    answer_source="deterministic",
                    needs_clarification=False,
                    missing_fields=v2_result.get("missing_fields", []),
                    query_spec=query_spec,
                    message=message,
                    model_response_mode=model_response_mode,
                    fallback_mode=fallback_mode,
                )
                return build_chat_response(
                    reply=v2_result.get("reply", ""),
                    insights=v2_result.get("insights", []),
                    actions=v2_result.get("actions", []),
                    citations=["deterministic_anchor_v2"],
                    intent=intent,
                    intent_confidence=intent_confidence,
                    intent_candidates=intent_candidates,
                    intent_source=intent_source,
                    needs_clarification=False,
                    context_source="deterministic_anchor_v2",
                    used_summary=used_summary,
                    tx_count_30d=tx_count_30d,
                    summary_empty=summary_empty,
                    answer_source="deterministic",
                    resolved_query=query_spec,
                    missing_fields=v2_result.get("missing_fields", []),
                    facts_used=v2_result.get("facts_used", []),
                    period_resolved=v2_result.get("period_resolved", ""),
                )

        # Deterministic fast-path for amount/month overview questions.
        # This avoids model hallucination on numeric queries.
        if intent == "recent_transactions" and self._should_use_deterministic(intent, query_spec):
            recent_anchor = self._recent_transactions_anchor(summary, max_items=5)
            if recent_anchor:
                self._debug_route_log(
                    intent_source=intent_source,
                    intent=intent,
                    intent_confidence=intent_confidence,
                    mode=mode,
                    answer_source="deterministic",
                    needs_clarification=needs_clarification,
                    missing_fields=[],
                    query_spec=query_spec,
                    message=message,
                    model_response_mode=model_response_mode,
                    fallback_mode=fallback_mode,
                )
                return build_chat_response(
                    reply=recent_anchor,
                    insights=["Recent transactions are read directly from validated summary rows."],
                    actions=[
                        "Ask for a specific date range or merchant if you want a narrower slice."
                    ],
                    citations=["deterministic_anchor"],
                    intent=intent,
                    intent_confidence=intent_confidence,
                    intent_candidates=intent_candidates,
                    intent_source=intent_source,
                    needs_clarification=False,
                    context_source="deterministic_anchor",
                    used_summary=used_summary,
                    tx_count_30d=tx_count_30d,
                    summary_empty=summary_empty,
                    answer_source="deterministic",
                    resolved_query=query_spec,
                    missing_fields=[],
                )
            self._debug_route_log(
                intent_source=intent_source,
                intent=intent,
                intent_confidence=intent_confidence,
                mode=mode,
                answer_source="deterministic",
                needs_clarification=False,
                missing_fields=[],
                query_spec=query_spec,
                message=message,
                model_response_mode=model_response_mode,
                fallback_mode=fallback_mode,
            )
            return build_chat_response(
                reply=f"I do not see recent transactions in the current summary for {self._scope_label(summary)}.",
                insights=["No recent transaction rows are available in the validated summary."],
                actions=["Refresh transactions, then ask again for recent activity."],
                citations=["deterministic_anchor"],
                intent=intent,
                intent_confidence=intent_confidence,
                intent_candidates=intent_candidates,
                intent_source=intent_source,
                needs_clarification=False,
                context_source="deterministic_anchor",
                used_summary=used_summary,
                tx_count_30d=tx_count_30d,
                summary_empty=summary_empty,
                answer_source="deterministic",
                resolved_query=query_spec,
                missing_fields=[],
            )
            missing_fields.append("recent_transactions")

        if intent == "category_spending" and self._should_use_deterministic(intent, query_spec):
            category_anchor = self._category_spending_anchor(summary, query_spec=query_spec)
            if category_anchor and "do not see" not in category_anchor.lower():
                self._debug_route_log(
                    intent_source=intent_source,
                    intent=intent,
                    intent_confidence=intent_confidence,
                    mode=mode,
                    answer_source="deterministic",
                    needs_clarification=needs_clarification,
                    missing_fields=[],
                    query_spec=query_spec,
                    message=message,
                    model_response_mode=model_response_mode,
                    fallback_mode=fallback_mode,
                )
                return build_chat_response(
                    reply=category_anchor,
                    insights=["Category amount is read from validated summary category indexes."],
                    actions=[
                        "Ask another period (month/year/last 30 days) to compare this category trend."
                    ],
                    citations=["deterministic_anchor"],
                    intent=intent,
                    intent_confidence=intent_confidence,
                    intent_candidates=intent_candidates,
                    intent_source=intent_source,
                    needs_clarification=False,
                    context_source="deterministic_anchor",
                    used_summary=used_summary,
                    tx_count_30d=tx_count_30d,
                    summary_empty=summary_empty,
                    answer_source="deterministic",
                    resolved_query=query_spec,
                    missing_fields=[],
                )
            if query_spec.get("category", ""):
                missing_fields.append("summary_data_for_category")
            else:
                missing_fields.append("category")

        if (
            intent == "top_category_lookup"
            or (
                intent_source == "rule"
                and self._is_factual_intent(intent)
                and self._asks_top_category(message)
            )
        ) and self._should_use_deterministic("top_category_lookup", query_spec):
            category_anchor = self._top_category_anchor(summary, message, query_spec=query_spec)
            missing = []
            if not category_anchor:
                category_anchor = (
                    f"I cannot find a category-level breakdown for this request in the current summary "
                    f"for {self._scope_label(summary)}."
                )
                missing = ["category_breakdown_for_period"]
            elif "do not see a monthly top-category breakdown" in category_anchor.lower():
                missing = ["category_breakdown_for_period"]
            self._debug_route_log(
                intent_source=intent_source,
                intent=intent,
                intent_confidence=intent_confidence,
                mode=mode,
                answer_source="deterministic",
                needs_clarification=needs_clarification,
                missing_fields=missing,
                query_spec=query_spec,
                message=message,
                model_response_mode=model_response_mode,
                fallback_mode=fallback_mode,
            )
            return build_chat_response(
                reply=category_anchor,
                insights=["Top-category answer is read directly from validated summary indexes."],
                actions=["Ask a follow-up for day-level transactions in that category if needed."],
                citations=["deterministic_anchor"],
                intent=intent,
                intent_confidence=intent_confidence,
                intent_candidates=intent_candidates,
                intent_source=intent_source,
                needs_clarification=needs_clarification,
                context_source="deterministic_anchor",
                used_summary=used_summary,
                tx_count_30d=tx_count_30d,
                summary_empty=summary_empty,
                answer_source="deterministic",
                resolved_query=query_spec,
                missing_fields=missing,
            )
        if (
            intent == "amount_lookup"
            or (
                intent_source == "rule"
                and self._is_factual_intent(intent)
                and self._asks_amount(message)
            )
        ) and self._should_use_deterministic("amount_lookup", query_spec):
            anchor = self._amount_anchor(summary, message, query_spec=query_spec)
            if anchor:
                self._debug_route_log(
                    intent_source=intent_source,
                    intent=intent,
                    intent_confidence=intent_confidence,
                    mode=mode,
                    answer_source="deterministic",
                    needs_clarification=needs_clarification,
                    missing_fields=[],
                    query_spec=query_spec,
                    message=message,
                    model_response_mode=model_response_mode,
                    fallback_mode=fallback_mode,
                )
                return build_chat_response(
                    reply=anchor,
                    insights=["Amount derived directly from validated summary indexes."],
                    actions=["Ask a follow-up for category or day-level breakdown if needed."],
                    citations=["deterministic_anchor"],
                    intent=intent,
                    intent_confidence=intent_confidence,
                    intent_candidates=intent_candidates,
                    intent_source=intent_source,
                    needs_clarification=needs_clarification,
                    context_source="deterministic_anchor",
                    used_summary=used_summary,
                    tx_count_30d=tx_count_30d,
                    summary_empty=summary_empty,
                    answer_source="deterministic",
                    resolved_query=query_spec,
                    missing_fields=[],
                )
            if query_spec.get("period_type") == "unknown":
                missing_fields.append("period")
            else:
                missing_fields.append("summary_data_for_period")
        if (
            intent == "month_overview"
            or (
                intent_source == "rule"
                and self._is_factual_intent(intent)
                and self._asks_month_overview(message)
            )
        ) and self._should_use_deterministic("month_overview", query_spec):
            month_anchor = self._months_overview_anchor(summary)
            if month_anchor:
                self._debug_route_log(
                    intent_source=intent_source,
                    intent=intent,
                    intent_confidence=intent_confidence,
                    mode=mode,
                    answer_source="deterministic",
                    needs_clarification=needs_clarification,
                    missing_fields=[],
                    query_spec=query_spec,
                    message=message,
                    model_response_mode=model_response_mode,
                    fallback_mode=fallback_mode,
                )
                return build_chat_response(
                    reply=month_anchor,
                    insights=["Month ranking is read from pre-computed summary rankings."],
                    actions=["Ask for a specific month to get exact total and top category."],
                    citations=["deterministic_anchor"],
                    intent=intent,
                    intent_confidence=intent_confidence,
                    intent_candidates=intent_candidates,
                    intent_source=intent_source,
                    needs_clarification=needs_clarification,
                    context_source="deterministic_anchor",
                    used_summary=used_summary,
                    tx_count_30d=tx_count_30d,
                    summary_empty=summary_empty,
                    answer_source="deterministic",
                    resolved_query=query_spec,
                    missing_fields=[],
                )
        if intent == "compare_periods" and self._should_use_deterministic(intent, query_spec):
            compare_anchor, compare_missing = self._compare_periods_anchor(
                summary, query_spec, message
            )
            if compare_anchor:
                self._debug_route_log(
                    intent_source=intent_source,
                    intent=intent,
                    intent_confidence=intent_confidence,
                    mode=mode,
                    answer_source="deterministic",
                    needs_clarification=needs_clarification,
                    missing_fields=[],
                    query_spec=query_spec,
                    message=message,
                    model_response_mode=model_response_mode,
                    fallback_mode=fallback_mode,
                )
                return build_chat_response(
                    reply=compare_anchor,
                    insights=[
                        "Period comparison is calculated directly from validated summary indexes."
                    ],
                    actions=[
                        "Ask a follow-up to break down the largest categories for each period."
                    ],
                    citations=["deterministic_anchor"],
                    intent=intent,
                    intent_confidence=intent_confidence,
                    intent_candidates=intent_candidates,
                    intent_source=intent_source,
                    needs_clarification=False,
                    context_source="deterministic_anchor",
                    used_summary=used_summary,
                    tx_count_30d=tx_count_30d,
                    summary_empty=summary_empty,
                    answer_source="deterministic",
                    resolved_query=query_spec,
                    missing_fields=[],
                )
            missing_fields.extend(compare_missing or ["summary_data_for_period"])
            self._debug_route_log(
                intent_source=intent_source,
                intent=intent,
                intent_confidence=intent_confidence,
                mode=mode,
                answer_source="clarification",
                needs_clarification=True,
                missing_fields=missing_fields,
                query_spec=query_spec,
                message=message,
                model_response_mode=model_response_mode,
                fallback_mode=fallback_mode,
            )
            return build_chat_response(
                reply="I can compare periods once you specify exact windows (for example, 2026-02 vs 2026-03).",
                insights=[
                    "Period comparison requires two explicit windows and available summary data for both."
                ],
                actions=["Ask: Compare 2026-02 and 2026-03 expenses for this scope."],
                citations=["clarification"],
                intent=intent,
                intent_confidence=intent_confidence,
                intent_candidates=intent_candidates,
                intent_source=intent_source,
                needs_clarification=True,
                context_source=context_source,
                used_summary=used_summary,
                tx_count_30d=tx_count_30d,
                summary_empty=summary_empty,
                answer_source="clarification",
                resolved_query=query_spec,
                missing_fields=missing_fields,
            )

        if (
            intent == "explain"
            and query_spec.get("period_type") == "month"
            and query_spec.get("reason_mode") == "spending_change"
        ):
            increase_anchor = self._spending_change_anchor(summary, query_spec)
            if increase_anchor:
                self._debug_route_log(
                    intent_source=intent_source,
                    intent=intent,
                    intent_confidence=intent_confidence,
                    mode=mode,
                    answer_source="deterministic",
                    needs_clarification=False,
                    missing_fields=[],
                    query_spec=query_spec,
                    message=message,
                    model_response_mode=model_response_mode,
                    fallback_mode=fallback_mode,
                )
                return build_chat_response(
                    reply=increase_anchor,
                    insights=[
                        "This compares the target month versus the prior month using validated month indexes."
                    ],
                    actions=[
                        "Ask for a category-by-category delta if you want a deeper breakdown."
                    ],
                    citations=["deterministic_anchor"],
                    intent=intent,
                    intent_confidence=intent_confidence,
                    intent_candidates=intent_candidates,
                    intent_source=intent_source,
                    needs_clarification=False,
                    context_source="deterministic_anchor",
                    used_summary=used_summary,
                    tx_count_30d=tx_count_30d,
                    summary_empty=summary_empty,
                    answer_source="deterministic",
                    resolved_query=query_spec,
                    missing_fields=[],
                )

        prompt = build_chat_prompt(intent, message, history, context_text)
        citations = [context_source]
        insights = []
        actions = []

        try:
            # Ask model for strict JSON output so Flutter can render structured cards.
            reply = self.generate_reply(
                prompt,
                generation_config={
                    "temperature": 0.3,
                    "maxOutputTokens": 420,
                    "responseMimeType": "application/json",
                },
            )
            parsed = extract_json_object(reply)
            if isinstance(parsed, dict):
                raw_reply = parsed.get("reply") or parsed.get("copy") or parsed.get("answer") or ""
                if isinstance(raw_reply, str):
                    reply_text = clamp_str(raw_reply, 2500)
                else:
                    reply_text = ""

                raw_insights = (
                    parsed.get("insights")
                    if isinstance(parsed.get("insights"), list)
                    else parsed.get("why")
                )
                raw_actions = (
                    parsed.get("actions")
                    if isinstance(parsed.get("actions"), list)
                    else parsed.get("next_actions")
                )
                if isinstance(raw_insights, list):
                    insights = [
                        clamp_str(x, 220) for x in raw_insights if isinstance(x, str) and x.strip()
                    ][:3]
                if isinstance(raw_actions, list):
                    actions = [
                        clamp_str(x, 220) for x in raw_actions if isinstance(x, str) and x.strip()
                    ][:3]

                # Small models get arithmetic wrong; drop any dollar figure not in the data.
                allowed = self._allowed_amounts(context_text, message)
                by_category = self._category_amounts(summary)
                reply_text = self._drop_ungrounded_sentences(reply_text, allowed, by_category)
                # Small models write "reduce it to 20% of current spend" for a 20% cut.
                reply_text = re.sub(
                    r"\bto (\d{1,2})% of (?:your )?(?:current |monthly )?(?:spend|spending|expenses)\b",
                    r"by \1%",
                    reply_text,
                )
                insights = [x for x in insights if self._amounts_grounded(x, allowed, by_category)]
                actions = [x for x in actions if self._amounts_grounded(x, allowed, by_category)]

                if not reply_text:
                    reply_text = self._fallback_reply(
                        intent, summary, message=message, query_spec=query_spec
                    )
                if not insights:
                    insights = ["This suggestion is based on your recent spending summary."]
                if not actions:
                    actions = ["Ask a follow-up question for a deeper breakdown."]
            else:
                # Fallback parse path for malformed/non-JSON model outputs.
                reply_text, insights, actions = self._parse_structured_text(clamp_str(reply, 2500))
                if not reply_text:
                    reply_text = self._fallback_reply(
                        intent, summary, message=message, query_spec=query_spec
                    )
                if not insights:
                    insights = ["This suggestion is based on your recent spending summary."]
                if not actions:
                    actions = ["Retry the request to get a fully structured response."]

            reply_text = clamp_str(reply_text, 2500)
            reply_text = self._sanitize_claim_text(reply_text)
            reply_text = self._dedupe_reply(reply_text, history, summary)
            if mode in ("deterministic", "hybrid") and (
                intent == "amount_lookup" or self._asks_amount(message)
            ):
                anchor = self._amount_anchor(summary, message, query_spec=query_spec)
                if anchor:
                    # Deterministic numeric anchor must be authoritative when user asks amount.
                    reply_text = clamp_str(anchor, 2500)
                    answer_source = "hybrid"
                elif not self._has_money_value(reply_text):
                    supplement = self._amount_supplement(summary, message)
                    if supplement:
                        reply_text = clamp_str(f"{reply_text} {supplement}".strip(), 2500)
                        answer_source = "hybrid"
            if mode in ("deterministic", "hybrid") and (
                intent == "month_overview" or self._asks_month_overview(message)
            ):
                month_anchor = self._months_overview_anchor(summary)
                if month_anchor and month_anchor.lower() not in (reply_text or "").lower():
                    reply_text = clamp_str(f"{reply_text} {month_anchor}".strip(), 2500)
                    answer_source = "hybrid"
            insights = self._sanitize_insights_accuracy(insights)
            insights = [
                clamp_str(x, 220) for x in (insights or []) if isinstance(x, str) and x.strip()
            ][:3]
            actions = [
                clamp_str(x, 220) for x in (actions or []) if isinstance(x, str) and x.strip()
            ][:3]
            actions = [self._sanitize_claim_text(x) for x in actions]
            actions = self._enforce_action_quality(actions, summary, intent=intent, message=message)
        except Exception:
            # Hard fallback keeps endpoint stable even if provider/model fails.
            context_source = "rule_fallback"
            answer_source = "deterministic_fallback"
            reply_text = self._fallback_reply(
                intent, summary, message=message, query_spec=query_spec
            )
            insights = ["Data coverage is limited, so this is a conservative suggestion."]
            actions = ["Refresh transactions, then ask again for a more precise answer."]
            citations = ["rule_fallback"]

        self._debug_route_log(
            intent_source=intent_source,
            intent=intent,
            intent_confidence=intent_confidence,
            mode=mode,
            answer_source=answer_source,
            needs_clarification=needs_clarification,
            missing_fields=missing_fields,
            query_spec=query_spec,
            message=message,
            model_response_mode=model_response_mode,
            fallback_mode=fallback_mode,
        )
        return build_chat_response(
            reply=reply_text,
            insights=insights,
            actions=actions,
            citations=citations,
            intent=intent,
            intent_confidence=intent_confidence,
            intent_candidates=intent_candidates,
            intent_source=intent_source,
            needs_clarification=needs_clarification,
            context_source=context_source,
            used_summary=used_summary,
            tx_count_30d=tx_count_30d,
            summary_empty=summary_empty,
            answer_source=answer_source,
            resolved_query=query_spec,
            missing_fields=missing_fields,
        )
