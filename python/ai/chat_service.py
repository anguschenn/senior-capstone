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
    CHINESE_MONTH_TO_NUM = {
        "一": 1,
        "二": 2,
        "三": 3,
        "四": 4,
        "五": 5,
        "六": 6,
        "七": 7,
        "八": 8,
        "九": 9,
        "十": 10,
        "十一": 11,
        "十二": 12,
        "正": 1,
    }

    def __init__(self, generate_reply, get_detailed_snapshot):
        self.generate_reply = generate_reply
        self.get_detailed_snapshot = get_detailed_snapshot
        self.router = IntentRouter()

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
        if intent == "compare":
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

    def _asks_amount(self, message):
        """Detect user questions that explicitly request numeric amount."""
        text = clamp_str(message or "", 4000).lower()
        if not text:
            return False
        if ("how much" in text) or ("amount" in text) or ("多少钱" in text):
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
        if "this month" in text or "month" in text:
            return "rolling_30d"
        if "this year" in text or "year" in text:
            return "annual_year"
        if any(name in text for name in self.MONTH_NAME_TO_NUM):
            return "annual_year"
        if re.search(r"\b20\d{2}-\d{2}\b", text):
            return "annual_year"
        if re.search(r"20\d{2}\s*年\s*\d{1,2}\s*月", text):
            return "annual_year"
        if re.search(r"\d{1,2}\s*月", text):
            return "annual_year"
        if re.search(r"(一|二|三|四|五|六|七|八|九|十|十一|十二)\s*月", text):
            return "annual_year"
        return "unknown"

    def _extract_specific_month_key(self, message, default_year):
        """Parse month reference from user message and return YYYY-MM key."""
        text = clamp_str(message or "", 4000).lower()
        if not text:
            return ""
        month_key_match = re.search(r"\b(20\d{2}-\d{2})\b", text)
        if month_key_match:
            return month_key_match.group(1)
        year_month_match = re.search(r"\b(20\d{2})[-/](\d{1,2})\b", text)
        if year_month_match:
            year = int(year_month_match.group(1))
            month = int(year_month_match.group(2))
            if 1 <= month <= 12:
                return f"{year}-{month:02d}"
        zh_year_month = re.search(r"(20\d{2})\s*年\s*(\d{1,2})\s*月", text)
        if zh_year_month:
            year = int(zh_year_month.group(1))
            month = int(zh_year_month.group(2))
            if 1 <= month <= 12:
                return f"{year}-{month:02d}"
        year_match = re.search(r"\b(20\d{2})\b", text)
        year = int(year_match.group(1)) if year_match else int(default_year or 0)
        if year <= 0:
            return ""
        for month_name, month_num in self.MONTH_NAME_TO_NUM.items():
            if re.search(rf"\b{re.escape(month_name)}\b", text):
                return f"{year}-{month_num:02d}"
        numeric_month = re.search(r"(?<!\d)(\d{1,2})\s*月", text)
        if numeric_month:
            month = int(numeric_month.group(1))
            if 1 <= month <= 12:
                return f"{year}-{month:02d}"
        zh_month = re.search(r"(十一|十二|一|二|三|四|五|六|七|八|九|十)\s*月", text)
        if zh_month:
            month_token = zh_month.group(1)
            month = self.CHINESE_MONTH_TO_NUM.get(month_token, 0)
            if 1 <= month <= 12:
                return f"{year}-{month:02d}"
        return ""

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
        if "which months" in text or "which month" in text:
            return True
        if "monthly spending" in text or "month by month" in text:
            return True
        return ("months" in text and "spend" in text) or ("月份" in text)

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

    def _amount_anchor(self, summary, message):
        """Always provide one authoritative amount sentence for requested window."""
        if not isinstance(summary, dict):
            return ""
        mode = self._timeframe_mode(message)
        month_index = summary.get("month_index") if isinstance(summary.get("month_index"), dict) else {}
        day_index_recent = (
            summary.get("day_index_recent")
            if isinstance(summary.get("day_index_recent"), dict)
            else {}
        )
        time_anchor = (
            summary.get("time_anchor")
            if isinstance(summary.get("time_anchor"), dict)
            else {}
        )
        selected_month_key = clamp_str(time_anchor.get("selected_month", ""), 16)
        selected_month_expenses = float(time_anchor.get("selected_month_expenses", 0) or 0)
        month_day_index = (
            summary.get("month_day_index")
            if isinstance(summary.get("month_day_index"), dict)
            else {}
        )
        annual = summary.get("annual_summary") if isinstance(summary.get("annual_summary"), dict) else {}
        annual_year = int(annual.get("year", 0) or 0)
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

        date_key = self._extract_specific_date_key(message, annual_year)
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

        month_key = self._extract_specific_month_key(message, annual_year)
        if month_key:
            if month_key == selected_month_key and selected_month_expenses >= 0:
                return (
                    f"For {month_key}, total expenses for {self._scope_label(summary)} "
                    f"are about ${selected_month_expenses:.0f}."
                )
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
            for item in monthly_top_categories:
                if not isinstance(item, dict):
                    continue
                if clamp_str(item.get("month", ""), 16) != month_key:
                    continue
                category = clamp_str(item.get("category", ""), 64)
                amount = float(item.get("amount", 0) or 0)
                if category and amount > 0:
                    return f"For {month_key}, the top category for {self._scope_label(summary)} is {category} at about ${amount:.0f}."
            return f"I do not see a monthly category breakdown for {month_key} in the current summary for {self._scope_label(summary)}."

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

    def handle_chat(self, payload, user_id=None):
        """Main chat pipeline: validate input, call model, normalize output."""
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

        # Deterministic fast-path for amount/month overview questions.
        # This avoids model hallucination on numeric queries.
        if self._asks_amount(message):
            anchor = self._amount_anchor(summary, message)
            if anchor:
                confidence = self._estimate_confidence(
                    context_source="deterministic_anchor",
                    used_summary=used_summary,
                    tx_count_30d=tx_count_30d,
                    summary_effectively_empty=summary_effectively_empty,
                )
                return build_chat_response(
                    reply=anchor,
                    insights=["Amount derived directly from validated summary indexes."],
                    actions=["Ask a follow-up for category or day-level breakdown if needed."],
                    confidence=confidence,
                    citations=["deterministic_anchor"],
                    intent=intent,
                    context_source="deterministic_anchor",
                    used_summary=used_summary,
                    tx_count_30d=tx_count_30d,
                    summary_empty=summary_empty,
                )
        if self._asks_month_overview(message):
            month_anchor = self._months_overview_anchor(summary)
            if month_anchor:
                confidence = self._estimate_confidence(
                    context_source="deterministic_anchor",
                    used_summary=used_summary,
                    tx_count_30d=tx_count_30d,
                    summary_effectively_empty=summary_effectively_empty,
                )
                return build_chat_response(
                    reply=month_anchor,
                    insights=["Month ranking is read from pre-computed summary rankings."],
                    actions=["Ask for a specific month to get exact total and top category."],
                    confidence=confidence,
                    citations=["deterministic_anchor"],
                    intent=intent,
                    context_source="deterministic_anchor",
                    used_summary=used_summary,
                    tx_count_30d=tx_count_30d,
                    summary_empty=summary_empty,
                )

        prompt = build_chat_prompt(intent, message, history, context_text)
        citations = [context_source]
        insights = []
        actions = []

        try:
            # Ask model for strict JSON output so Flutter can render structured cards.
            reply = self.generate_reply(
                prompt,
                generation_config={"temperature": 0.65, "maxOutputTokens": 420, "responseMimeType": "application/json"},
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
                    insights = ["The response used only validated context fields."]
                if not actions:
                    actions = ["Ask a follow-up question for a deeper breakdown."]
            else:
                # Fallback parse path for malformed/non-JSON model outputs.
                reply_text, insights, actions = self._parse_structured_text(clamp_str(reply, 2500))
                if not reply_text:
                    reply_text = self._fallback_reply(intent, summary)
                if not insights:
                    insights = ["The assistant fell back to plain-text parsing because JSON output was invalid."]
                if not actions:
                    actions = ["Retry the request to get a fully structured response."]

            reply_text = clamp_str(reply_text, 2500)
            reply_text = self._dedupe_reply(reply_text, history, summary)
            if self._asks_amount(message):
                anchor = self._amount_anchor(summary, message)
                if anchor:
                    # Deterministic numeric anchor must be authoritative when user asks amount.
                    reply_text = clamp_str(anchor, 2500)
                elif not self._has_money_value(reply_text):
                    supplement = self._amount_supplement(summary, message)
                    if supplement:
                        reply_text = clamp_str(f"{reply_text} {supplement}".strip(), 2500)
            if self._asks_month_overview(message):
                month_anchor = self._months_overview_anchor(summary)
                if month_anchor and month_anchor.lower() not in (reply_text or "").lower():
                    reply_text = clamp_str(f"{reply_text} {month_anchor}".strip(), 2500)
            insights = [clamp_str(x, 220) for x in (insights or []) if isinstance(x, str) and x.strip()][:3]
            actions = [clamp_str(x, 220) for x in (actions or []) if isinstance(x, str) and x.strip()][:3]
            actions = self._enforce_action_quality(actions, summary)
        except Exception:
            # Hard fallback keeps endpoint stable even if provider/model fails.
            context_source = "rule_fallback"
            reply_text = self._fallback_reply(intent, summary)
            insights = ["Recent data coverage is limited, so this is a conservative fallback."]
            actions = ["Refresh transactions, then ask again for a more precise answer."]
            citations = ["rule_fallback"]

        confidence = self._estimate_confidence(
            context_source=context_source,
            used_summary=used_summary,
            tx_count_30d=tx_count_30d,
            summary_effectively_empty=summary_effectively_empty,
        )

        return build_chat_response(
            reply=reply_text,
            insights=insights,
            actions=actions,
            confidence=confidence,
            citations=citations,
            intent=intent,
            context_source=context_source,
            used_summary=used_summary,
            tx_count_30d=tx_count_30d,
            summary_empty=summary_empty,
        )
