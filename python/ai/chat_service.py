import re
from datetime import date as date_cls

from .explainers import build_chat_prompt
from .intent_router import IntentRouter
from .parsers import extract_json_object
from .schemas import build_chat_response
from .validators import sanitize_history, sanitize_spending_summary, clamp_str


class ChatService:
    """Orchestrates AI chat with validated financial context and safe fallbacks."""

    MONTH_NAME_TO_NUM = {
        "january": 1, "jan": 1,
        "february": 2, "feb": 2,
        "march": 3, "mar": 3,
        "april": 4, "apr": 4,
        "may": 5,
        "june": 6, "jun": 6,
        "july": 7, "jul": 7,
        "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10,
        "november": 11, "nov": 11,
        "december": 12, "dec": 12,
    }
    HIGH_CONFIDENCE_THRESHOLD = 0.70
    MID_CONFIDENCE_THRESHOLD = 0.45

    def __init__(self, generate_reply, get_detailed_snapshot):
        self.generate_reply = generate_reply
        self.get_detailed_snapshot = get_detailed_snapshot
        self.router = IntentRouter(classify_with_llm=generate_reply)

    def _summary_to_text(self, summary):
        """Convert structured summary JSON into compact prompt context text."""
        if not isinstance(summary, dict):
            return "No summary available."
        totals = summary.get("totals") or {}
        categories = summary.get("top_expense_categories") or []
        recent = summary.get("recent_transactions") or []
        cat_text = ", ".join(
            f"{c.get('category')} ${float(c.get('amount', 0)):.0f}" for c in categories[:5]
        ) or "none"
        recent_text = ", ".join(
            f"{t.get('date')} {t.get('name')} ${float(t.get('amount', 0)):.0f}"
            for t in recent[:5]
        ) or "none"
        annual = summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
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
        annual_cat_text = ", ".join(
            f"{c.get('category')} ${float(c.get('amount', 0)):.0f}" for c in annual_categories[:5]
        ) or "none"
        high_month_text = ", ".join(
            f"{m.get('month')} ${float(m.get('expenses', 0)):.0f}"
            for m in monthly_expense_ranking[:3]
            if isinstance(m, dict)
        ) or "none"
        trend_tail = monthly_expense_trend[-3:] if len(monthly_expense_trend) > 3 else monthly_expense_trend
        trend_text = ", ".join(
            f"{m.get('month')} {float(m.get('expenses', 0)):.0f}"
            for m in trend_tail
            if isinstance(m, dict)
        ) or "none"
        month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
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
        v2_month_text = ", ".join(
            f"{clamp_str(m.get('month', ''), 16)} ${float(m.get('expenses', 0)):.0f}"
            for m in top_months[:3]
            if isinstance(m, dict) and clamp_str(m.get("month", ""), 16)
        ) or "none"
        v2_day_text = ", ".join(
            f"{clamp_str(d.get('date', ''), 16)} ${float(d.get('expenses', 0)):.0f}"
            for d in top_days_recent[:3]
            if isinstance(d, dict) and clamp_str(d.get("date", ""), 16)
        ) or "none"
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

        return (
            f"30d income: ${float(totals.get('income_30d', 0)):.2f}; "
            f"30d expenses: ${float(totals.get('expenses_30d', 0)):.2f}; "
            f"tx_count_30d: {int(totals.get('tx_count_30d', 0))}; "
            f"expense_tx_count_30d: {int(totals.get('expense_tx_count_30d', 0))}; "
            f"top categories: {cat_text}; "
            f"recent transactions: {recent_text}"
            f"{annual_text}"
        )

    def _fallback_reply(self, intent, summary):
        """Return deterministic reply when model output is unavailable/invalid."""
        totals = (summary or {}).get("totals") if isinstance(summary, dict) else {}
        if not isinstance(totals, dict):
            totals = {}
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

        annual_has_signal = (
            annual_income > 0 or annual_expenses > 0 or annual_expense_tx > 0
        )
        annual_top_text = ", ".join(
            f"{c.get('category')} ${float(c.get('amount', 0)):.0f}" for c in annual_categories[:3]
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
            return "Start with a fixed monthly target, cap top spending categories, and review weekly."
        return f"Based on your recent snapshot: income ${income:.0f}, expenses ${expenses:.0f} over 30 days."

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

    def _estimate_confidence(self, context_source, used_summary, tx_count_30d, summary_effectively_empty):
        """Derive a bounded confidence score for UI display."""
        if context_source == "rule_fallback":
            return 0.35
        if context_source == "server_snapshot":
            return 0.65
        if used_summary and tx_count_30d > 10 and not summary_effectively_empty:
            return 0.75
        if used_summary:
            return 0.55
        return 0.4

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

    def _is_transfer_category(self, name):
        """Classify transfer/internal categories to avoid bad advice targets."""
        text = clamp_str(name or "", 128).lower()
        if not text:
            return False
        return "transfer" in text or "internal" in text

    def _best_spend_target(self, summary):
        """Pick the best discretionary spend category candidate for action text."""
        if not isinstance(summary, dict):
            return None
        categories = summary.get("top_expense_categories")
        if not isinstance(categories, list):
            return None
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

    def _enforce_action_quality(self, actions, summary):
        """Ensure at least one actionable, quantified recommendation exists."""
        current = [clamp_str(x, 220) for x in (actions or []) if isinstance(x, str) and x.strip()]
        current = current[:3]
        if self._has_quantified_action(current):
            return current

        target = self._best_spend_target(summary)
        if target:
            monthly = target["amount"]
            lower = max(5.0, round(monthly * 0.12, 2))
            upper = max(lower, round(monthly * 0.2, 2))
            quantified = clamp_str(
                f"Over the next 14 days, reduce {target['name']} by 15-20% to save about ${lower:.0f}-${upper:.0f}.",
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
                (" times " in f" {lower} " or "times recently" in lower or "times this" in lower)
                and has_number
            )
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
            (" times " in f" {lower} " or "times recently" in lower or "times this" in lower)
            and has_number
        )
        # Generic consistency guard: when text states a total and also mentions
        # component dollar amounts, no component should exceed the total.
        total_match = re.search(r"\btotal\s+\$([0-9]+(?:\.[0-9]+)?)", lower)
        if total_match:
            total = float(total_match.group(1))
            dollar_values = [
                float(m.group(1))
                for m in re.finditer(r"\$([0-9]+(?:\.[0-9]+)?)", lower)
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
            or any(name in text for name in self.MONTH_NAME_TO_NUM)
        ):
            return True
        return False

    def _asks_top_category(self, message):
        """Detect user questions asking for the highest-spend category."""
        text = clamp_str(message or "", 4000).lower()
        if not text:
            return False
        has_category_term = (
            "category" in text
            or "categories" in text
        )
        has_top_term = (
            "most" in text
            or "top" in text
            or "highest" in text
            or "max" in text
        )
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
                last_month = self._previous_month_key()
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
                    "period_key": date_cls.today().strftime("%Y-%m"),
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
                    "metric": "expenses",
                    "period_type": "month_range",
                    "period_key": ",".join(range_keys[:6]),
                    "scope": self._scope_key(summary),
                }
            if "last month" in text:
                last_month = self._previous_month_key()
                if last_month:
                    return {
                        "intent": "amount_lookup",
                        "metric": "expenses",
                        "period_type": "month",
                        "period_key": last_month,
                        "scope": self._scope_key(summary),
                    }
            if "this month" in text:
                return {
                    "intent": "amount_lookup",
                    "metric": "expenses",
                    "period_type": "month",
                    "period_key": date_cls.today().strftime("%Y-%m"),
                    "scope": self._scope_key(summary),
                }
            date_key = self._extract_specific_date_key(message, annual_year)
            if date_key:
                return {
                    "intent": "amount_lookup",
                    "metric": "expenses",
                    "period_type": "day",
                    "period_key": date_key,
                    "scope": self._scope_key(summary),
                }
            month_key = self._extract_specific_month_key(message, annual_year)
            if month_key:
                return {
                    "intent": "amount_lookup",
                    "metric": "expenses",
                    "period_type": "month",
                    "period_key": month_key,
                    "scope": self._scope_key(summary),
                }
            if "last 30 days" in text or "30 days" in text or "30d" in text:
                return {
                    "intent": "amount_lookup",
                    "metric": "expenses",
                    "period_type": "rolling_30d",
                    "period_key": "rolling_30d",
                    "scope": self._scope_key(summary),
                }
            if "last year" in text:
                return {
                    "intent": "amount_lookup",
                    "metric": "expenses",
                    "period_type": "year",
                    "period_key": self._previous_year_key(),
                    "scope": self._scope_key(summary),
                }
            if "this year" in text or "year" in text or re.search(r"\b20\d{2}\b", text):
                year_match = re.search(r"\b(20\d{2})\b", text)
                year_key = year_match.group(1) if year_match else str(annual_year)
                return {
                    "intent": "amount_lookup",
                    "metric": "expenses",
                    "period_type": "year",
                    "period_key": year_key,
                    "scope": self._scope_key(summary),
                }
            return {
                "intent": "amount_lookup",
                "metric": "expenses",
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
        if "today" in text or "yesterday" in text:
            return "specific_day"
        if "last 30 days" in text or "30 days" in text or "30d" in text:
            return "rolling_30d"
        if "which month" in text or "which months" in text or "months" in text:
            return "annual_year"
        if "this month" in text:
            return "selected_month"
        if "month" in text:
            return "rolling_30d"
        if "this year" in text or "year" in text:
            return "annual_year"
        if any(name in text for name in self.MONTH_NAME_TO_NUM):
            return "annual_year"
        if re.search(r"\b20\d{2}-\d{2}\b", text):
            return "annual_year"
        return "unknown"

    def _extract_specific_month_key(self, message, default_year):
        """Parse month reference from user message and return YYYY-MM key."""
        text = clamp_str(message or "", 4000).lower()
        if not text:
            return ""
        if "last month" in text:
            return self._previous_month_key()
        month_key_match = re.search(r"\b(20\d{2}-\d{2})\b", text)
        if month_key_match:
            return month_key_match.group(1)
        year_month_match = re.search(r"\b(20\d{2})[-/](\d{1,2})\b", text)
        if year_month_match:
            year = int(year_month_match.group(1))
            month = int(year_month_match.group(2))
            if 1 <= month <= 12:
                return f"{year}-{month:02d}"
        year_match = re.search(r"\b(20\d{2})\b", text)
        year = int(year_match.group(1)) if year_match else int(default_year or 0)
        if year <= 0:
            return ""
        for month_name, month_num in self.MONTH_NAME_TO_NUM.items():
            if re.search(rf"\b{re.escape(month_name)}\b", text):
                return f"{year}-{month_num:02d}"
        return ""

    def _previous_month_key(self):
        """Return previous calendar month in YYYY-MM format."""
        today = date_cls.today()
        year = today.year
        month = today.month - 1
        if month <= 0:
            month = 12
            year -= 1
        return f"{year}-{month:02d}"

    def _previous_year_key(self):
        """Return previous calendar year as YYYY string."""
        return str(date_cls.today().year - 1)

    def _extract_month_range_keys(self, message, default_year):
        """Extract month range keys for phrases like last 3 months."""
        text = clamp_str(message or "", 4000).lower()
        if not text:
            return []

        explicit = re.findall(r"\b20\d{2}-\d{2}\b", text)
        if len(explicit) >= 2:
            return explicit[:6]

        last_n = re.search(r"\blast\s+(\d{1,2})\s+months?\b", text)
        if last_n:
            count = max(2, min(12, int(last_n.group(1))))
            keys = []
            year, month = date_cls.today().year, date_cls.today().month
            # last N complete months (exclude current month)
            for _ in range(count):
                month -= 1
                if month <= 0:
                    month = 12
                    year -= 1
                keys.append(f"{year}-{month:02d}")
            keys.reverse()
            return keys

        first_n = re.search(r"\bfirst\s+(\d{1,2})\s+months?\b", text)
        if first_n:
            count = max(2, min(12, int(first_n.group(1))))
            year_match = re.search(r"\b(20\d{2})\b", text)
            year = int(year_match.group(1)) if year_match else int(default_year or date_cls.today().year)
            return [f"{year}-{m:02d}" for m in range(1, count + 1)]

        return []

    def _extract_specific_date_key(self, message, default_year):
        """Parse date reference from user message and return YYYY-MM-DD key."""
        text = clamp_str(message or "", 4000).lower()
        if not text:
            return ""

        iso_match = re.search(r"\b(20\d{2}-\d{2}-\d{2})\b", text)
        if iso_match:
            return iso_match.group(1)

        if "today" in text:
            return date_cls.today().isoformat()
        if "yesterday" in text:
            return date_cls.fromordinal(date_cls.today().toordinal() - 1).isoformat()

        year_match = re.search(r"\b(20\d{2})\b", text)
        year = int(year_match.group(1)) if year_match else int(default_year or 0)
        if year <= 0:
            return ""

        for month_name, month_num in self.MONTH_NAME_TO_NUM.items():
            # Supports "march 15", "march 15th", "mar 15"
            match = re.search(rf"\b{re.escape(month_name)}\s+(\d{{1,2}})(st|nd|rd|th)?\b", text)
            if not match:
                continue
            day = int(match.group(1))
            if day < 1 or day > 31:
                continue
            return f"{year}-{month_num:02d}-{day:02d}"
        return ""

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
        return ("months" in text and "spend" in text)

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
                    text = ", ".join(
                        f"{month} (${expenses:.0f})" for month, expenses in normalized
                    )
                    return (
                        f"Highest spending months for {self._scope_label(summary)}: {text}."
                    )
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
                    return (
                        f"Highest spending months for {self._scope_label(summary)}: {text}."
                    )
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
                annual = summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
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
                top_category, top_amount = sorted(by_category.items(), key=lambda kv: kv[1], reverse=True)[0]
                return (
                    f"For {range_keys[0]} to {range_keys[-1]}, based on monthly top-category summaries for "
                    f"{self._scope_label(summary)}, the top category is {top_category} at about ${top_amount:.0f}."
                )
        annual = summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
        spec = query_spec if isinstance(query_spec, dict) else {}
        requested_year = clamp_str(spec.get("period_key", ""), 8) if clamp_str(spec.get("period_type", ""), 24) == "year" else ""
        annual_year = str(int(annual.get("year", 0) or 0))
        if requested_year and annual_year and requested_year != annual_year:
            return (
                f"I do not see a yearly category breakdown for {requested_year} "
                f"in the current summary for {self._scope_label(summary)}."
            )
        annual_year_int = int(annual.get("year", 0) or 0)
        month_key = self._extract_specific_month_key(message, annual_year_int)
        month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
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
        def _fmt_amount(value):
            abs_value = abs(float(value or 0))
            sign = "-" if value < 0 else "+"
            return f"{sign}${abs_value:.0f}"

        text = "; ".join(f"{d} {n} {_fmt_amount(a)}" for d, n, a in rows)
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
        month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
        annual = summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
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
        annual = summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
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
        mode = self._timeframe_mode(message)
        month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
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
        annual = summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
        annual_year = int(annual.get("year", 0) or 0)
        year_index = summary.get("year_index") if isinstance(summary.get("year_index"), dict) else {}
        annual_totals = annual.get("totals") if isinstance(annual.get("totals"), dict) else {}
        annual_categories = (
            annual.get("top_expense_categories_year")
            if isinstance(annual.get("top_expense_categories_year"), list)
            else []
        )
        monthly_top_categories = (
            annual.get("monthly_top_categories")
            if isinstance(annual.get("monthly_top_categories"), list)
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
            month_keys = [clamp_str(x.strip(), 16) for x in spec_key.split(",") if clamp_str(x.strip(), 16)]
            if len(month_keys) >= 2:
                total = 0.0
                for key in month_keys:
                    row = month_index.get(key)
                    if not isinstance(row, dict):
                        return ""
                    total += float(row.get("expenses", 0) or 0)
                return (
                    f"For {month_keys[0]} to {month_keys[-1]}, total expenses for {self._scope_label(summary)} "
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
                    total += float(item.get("expenses", 0) or 0)
                    matched += 1
                if matched > 0:
                    coverage_ratio = matched / max(1, days)
                    coverage_note = (
                        " (based on limited recorded days in this window)"
                        if coverage_ratio < 0.4
                        else ""
                    )
                    return (
                        f"For the last {days} days, total recorded expenses for {self._scope_label(summary)} "
                        f"are about ${total:.0f}{coverage_note}."
                    )
                return (
                    f"I do not see enough recent daily data for the last {days} days "
                    f"for {self._scope_label(summary)}."
                )
        if spec_type == "year" and spec_key:
            row = year_index.get(spec_key)
            if isinstance(row, dict):
                amount = float(row.get("expenses", 0) or 0)
                return (
                    f"For {spec_key}, total recorded expenses for {self._scope_label(summary)} "
                    f"are about ${amount:.0f}."
                )
            if str(annual_year) == spec_key:
                amount = float(annual_totals.get("expenses_year", 0) or 0)
                return (
                    f"For {spec_key}, total recorded expenses for {self._scope_label(summary)} "
                    f"are about ${amount:.0f}."
                )
            return (
                f"I do not see recorded expenses for {spec_key} in the current summary "
                f"for {self._scope_label(summary)}."
            )

        date_key = spec_key if spec_type == "day" else self._extract_specific_date_key(message, annual_year)
        if date_key:
            v2_day = day_index_recent.get(date_key)
            if isinstance(v2_day, dict):
                amount = float(v2_day.get("expenses", 0) or 0)
                return (
                    f"For {date_key}, recorded expenses for {self._scope_label(summary)} "
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
                    amount = float(row.get("expenses", 0) or 0)
                    return (
                        f"For {date_key}, recorded expenses for {self._scope_label(summary)} "
                        f"are about ${amount:.0f}."
                    )
            for item in daily_expense_totals:
                if not isinstance(item, dict):
                    continue
                if clamp_str(item.get("date", ""), 16) != date_key:
                    continue
                amount = float(item.get("amount", 0) or 0)
                return f"For {date_key}, recorded expenses for {self._scope_label(summary)} are about ${amount:.0f}."
            return f"I do not see recorded expenses for {date_key} in the current summary for {self._scope_label(summary)}."

        month_key = spec_key if spec_type == "month" else self._extract_specific_month_key(message, annual_year)
        if month_key:
            v2_month = month_index.get(month_key)
            if isinstance(v2_month, dict):
                month_expenses = float(v2_month.get("expenses", 0) or 0)
                top = v2_month.get("top_category")
                if isinstance(top, dict):
                    top_name = clamp_str(top.get("name", ""), 64)
                    top_amount = float(top.get("amount", 0) or 0)
                    if top_name and top_amount > 0:
                        return (
                            f"For {month_key}, total expenses for {self._scope_label(summary)} "
                            f"are about ${month_expenses:.0f}; top category is {top_name} at about ${top_amount:.0f}."
                        )
                return (
                    f"For {month_key}, total expenses for {self._scope_label(summary)} "
                    f"are about ${month_expenses:.0f}."
                )
            return (
                f"I do not see recorded expenses for {month_key} in the current summary "
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
        return intent in {
            "amount_lookup",
            "top_category_lookup",
            "month_overview",
            "compare_periods",
            "recent_transactions",
            "category_spending",
        }

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
        mode = model_mode if isinstance(model_mode, str) and model_mode in allowed else fallback_mode
        factual_intents = {
            "amount_lookup",
            "top_category_lookup",
            "month_overview",
            "compare_periods",
            "recent_transactions",
            "category_spending",
        }
        query_complete = self._is_query_complete(query_spec, intent)
        if mode == "deterministic" and not query_complete:
            return "clarification"
        if mode == "llm" and intent in factual_intents and query_complete:
            return "hybrid"
        return mode

    def _merge_query_spec(self, base_spec, entities):
        """Merge model entities into query spec, preferring explicit non-unknown values."""
        merged = dict(base_spec or {})
        if not isinstance(entities, dict):
            return merged
        for key in ("metric", "period_type", "period_key", "scope", "intent", "category", "compare_to"):
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
        factual = {
            "amount_lookup",
            "top_category_lookup",
            "month_overview",
            "compare_periods",
            "recent_transactions",
            "category_spending",
        }
        if intent not in factual:
            return True
        period_type = clamp_str(query_spec.get("period_type", ""), 24) or "unknown"
        period_key = clamp_str(query_spec.get("period_key", ""), 64)
        if period_type == "month_range" and intent in {"amount_lookup", "top_category_lookup"}:
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
        month_names = []
        for name, num in self.MONTH_NAME_TO_NUM.items():
            if re.search(rf"\b{re.escape(name)}\b", text):
                month_names.append(num)
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
        month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
        year_index = summary.get("year_index") if isinstance(summary.get("year_index"), dict) else {}

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
                annual = summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
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

    def _should_clarify(self, intent_confidence, needs_clarification, query_spec, intent):
        """Calibrated clarification gate based on confidence and query completeness."""
        factual_intents = {
            "amount_lookup",
            "top_category_lookup",
            "month_overview",
            "compare_periods",
            "recent_transactions",
            "category_spending",
        }
        query_complete = self._is_query_complete(query_spec, intent)
        if intent not in factual_intents:
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
        print(
            "[ai.chat.route] "
            f"intent_source={intent_source} intent={intent} confidence={intent_confidence:.2f} "
            f"response_mode_model={rm_model} response_mode_from_intent={rm_intent} response_mode_final={rm_final} "
            f"answer_source={answer_source} needs_clarification={bool(needs_clarification)} "
            f"missing_fields={','.join(missing_fields or []) or 'none'} period_type={period_type} "
            f"period_key={period_key or 'none'} prompt_len={len(message or '')}"
        )

    def handle_chat(self, payload, user_id=None):
        """Main chat pipeline: validate input, call model, normalize output."""
        payload = payload or {}
        message = clamp_str(payload.get("prompt", ""), 4000)
        if not message:
            raise ValueError("Missing prompt")

        history = sanitize_history(payload.get("history"), max_turns=6)
        summary = sanitize_spending_summary(payload.get("spending_summary"))
        intent_result = self.router.classify(message, history)
        intent = intent_result.get("intent", "general")
        intent_confidence = float(intent_result.get("intent_confidence", 0.0) or 0.0)
        intent_candidates = intent_result.get("intent_candidates") or [intent]
        intent_source = intent_result.get("intent_source", "rule")
        needs_clarification = bool(intent_result.get("needs_clarification", False))
        model_response_mode = clamp_str(intent_result.get("response_mode", ""), 24)
        entities = intent_result.get("entities") if isinstance(intent_result.get("entities"), dict) else {}
        clarification_question = clamp_str(intent_result.get("clarification_question", ""), 180)
        query_spec = {
            "intent": clamp_str(intent, 24) or "general",
            "metric": "unknown",
            "period_type": "unknown",
            "period_key": "",
            "category": "",
            "compare_to": "",
            "scope": self._scope_key(summary),
        }
        query_spec = self._merge_query_spec(query_spec, entities)
        if not self._is_query_complete(query_spec, intent):
            fallback_spec = self._extract_query_spec(message, summary, intent)
            query_spec = self._merge_query_spec(fallback_spec, entities)
        fallback_mode = self._resolve_response_mode(intent)
        mode = self._sanitize_response_mode(model_response_mode, intent, query_spec, fallback_mode)
        summary_meta = (summary or {}).get("totals") or {}
        tx_count_30d = int(summary_meta.get("tx_count_30d", 0) or 0)
        summary_empty = summary is None

        context_source = "frontend_summary"
        used_summary = summary is not None

        income_30d = float(summary_meta.get("income_30d", 0) or 0)
        expenses_30d = float(summary_meta.get("expenses_30d", 0) or 0)
        expense_tx_30d = int(summary_meta.get("expense_tx_count_30d", 0) or 0)
        annual_summary = (summary or {}).get("annual_summary") if isinstance(summary, dict) else {}
        if not isinstance(annual_summary, dict):
            annual_summary = {}
        annual_totals = (
            annual_summary.get("totals")
            if isinstance(annual_summary.get("totals"), dict)
            else {}
        )
        if not isinstance(annual_totals, dict):
            annual_totals = {}
        annual_income = float(annual_totals.get("income_year", 0) or 0)
        annual_expenses = float(annual_totals.get("expenses_year", 0) or 0)
        annual_expense_tx = int(annual_totals.get("expense_tx_count_year", 0) or 0)
        annual_has_signal = annual_income > 0 or annual_expenses > 0 or annual_expense_tx > 0
        summary_effectively_empty = (
            summary is None
            or (
                income_30d <= 0
                and expenses_30d <= 0
                and tx_count_30d <= 0
                and expense_tx_30d <= 0
                and not annual_has_signal
            )
        )
        # Product rule: chat only uses app-sent summary; no server DB read fallback.
        context_text = self._summary_to_text(summary)
        if summary is None:
            context_source = "frontend_summary_empty"
            used_summary = False
        answer_source = "llm"
        missing_fields = []
        should_clarify = self._should_clarify(
            intent_confidence=intent_confidence,
            needs_clarification=needs_clarification,
            query_spec=query_spec,
            intent=intent,
        )
        if mode == "clarification":
            should_clarify = True
        if should_clarify and (intent_source == "llm" or clarification_question or mode != "llm"):
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
                    actions=["Ask for a specific date range or merchant if you want a narrower slice."],
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
                    actions=["Ask another period (month/year/last 30 days) to compare this category trend."],
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
            compare_anchor, compare_missing = self._compare_periods_anchor(summary, query_spec, message)
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
                    insights=["Period comparison is calculated directly from validated summary indexes."],
                    actions=["Ask a follow-up to break down the largest categories for each period."],
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
                insights=["Period comparison requires two explicit windows and available summary data for both."],
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

        prompt = build_chat_prompt(intent, message, history, context_text)
        citations = [context_source]
        insights = []
        actions = []

        try:
            # Ask model for strict JSON output so Flutter can render structured cards.
            reply = self.generate_reply(
                prompt,
                generation_config={"temperature": 0.3, "maxOutputTokens": 420, "responseMimeType": "application/json"},
            )
            parsed = extract_json_object(reply)
            if isinstance(parsed, dict):
                raw_reply = (
                    parsed.get("reply")
                    or parsed.get("copy")
                    or parsed.get("answer")
                    or ""
                )
                if isinstance(raw_reply, str):
                    reply_text = clamp_str(raw_reply, 2500)
                else:
                    reply_text = ""

                raw_insights = parsed.get("insights") if isinstance(parsed.get("insights"), list) else parsed.get("why")
                raw_actions = parsed.get("actions") if isinstance(parsed.get("actions"), list) else parsed.get("next_actions")
                if isinstance(raw_insights, list):
                    insights = [clamp_str(x, 220) for x in raw_insights if isinstance(x, str) and x.strip()][:3]
                if isinstance(raw_actions, list):
                    actions = [clamp_str(x, 220) for x in raw_actions if isinstance(x, str) and x.strip()][:3]

                if not reply_text:
                    reply_text = self._fallback_reply(intent, summary)
                if not insights:
                    insights = ["This suggestion is based on your recent spending summary."]
                if not actions:
                    actions = ["Ask a follow-up question for a deeper breakdown."]
            else:
                # Fallback parse path for malformed/non-JSON model outputs.
                reply_text, insights, actions = self._parse_structured_text(clamp_str(reply, 2500))
                if not reply_text:
                    reply_text = self._fallback_reply(intent, summary)
                if not insights:
                    insights = ["This suggestion is based on your recent spending summary."]
                if not actions:
                    actions = ["Retry the request to get a fully structured response."]

            reply_text = clamp_str(reply_text, 2500)
            reply_text = self._sanitize_claim_text(reply_text)
            reply_text = self._dedupe_reply(reply_text, history, summary)
            if mode in ("deterministic", "hybrid") and (intent == "amount_lookup" or self._asks_amount(message)):
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
            if mode in ("deterministic", "hybrid") and (intent == "month_overview" or self._asks_month_overview(message)):
                month_anchor = self._months_overview_anchor(summary)
                if month_anchor and month_anchor.lower() not in (reply_text or "").lower():
                    reply_text = clamp_str(f"{reply_text} {month_anchor}".strip(), 2500)
                    answer_source = "hybrid"
            insights = self._sanitize_insights_accuracy(insights)
            insights = [clamp_str(x, 220) for x in (insights or []) if isinstance(x, str) and x.strip()][:3]
            actions = [clamp_str(x, 220) for x in (actions or []) if isinstance(x, str) and x.strip()][:3]
            actions = [self._sanitize_claim_text(x) for x in actions]
            actions = self._enforce_action_quality(actions, summary)
        except Exception:
            # Hard fallback keeps endpoint stable even if provider/model fails.
            context_source = "rule_fallback"
            answer_source = "deterministic_fallback"
            reply_text = self._fallback_reply(intent, summary)
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
