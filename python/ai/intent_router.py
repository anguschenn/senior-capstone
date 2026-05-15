import json
import re
from datetime import date as date_cls

from .time_parsing import extract_period


class IntentRouter:
    """Hybrid intent router: rule-first, LLM fallback, strict post-LLM validation."""

    VALID_TASK_TYPES = {
        "factual_query",
        "advice_request",
        "causal_explanation",
        "what_if",
        "unknown",
    }
    VALID_INTENTS = {
        "amount_lookup",
        "top_category_lookup",
        "category_spending",
        "recent_transactions",
        "month_overview",
        "compare_periods",
        "general",
        "explain",
        "what_if",
        "planning",
    }
    VALID_RESPONSE_MODES = {"deterministic", "hybrid", "llm", "clarification"}
    VALID_METRICS = {"expenses", "income", "net", "top_category", "unknown"}
    VALID_PERIOD_TYPES = {
        "day",
        "month",
        "month_range",
        "year",
        "rolling_30d",
        "rolling_days",
        "custom",
        "unknown",
    }

    VAGUE_SINGLE_WORDS = {
        "money",
        "spending",
        "expense",
        "expenses",
        "income",
        "budget",
        "finance",
        "help",
        "how",
        "why",
        "what",
    }
    EXPLAIN_KEYWORDS = ("why", "explain", "reason", "because")
    COMPARE_KEYWORDS = ("compare", "difference", "vs", "versus")
    WHAT_IF_KEYWORDS = ("what if", "if i", "scenario", "simulate")
    PLANNING_KEYWORDS = ("should", "save", "plan", "goal", "roadmap", "improve")
    GENERAL_ADVISORY_KEYWORDS = ("advice", "how am i doing", "help me")
    TOP_CATEGORY_KEYWORDS = (
        "top category",
        "highest category",
        "most category",
        "top spend category",
        "spent most on",
        "spend most on",
        "#1 spend category",
    )
    RECENT_TX_KEYWORDS = (
        "recent transactions",
        "latest transactions",
        "recent activity",
        "latest activity",
        "recent purchases",
        "last few transactions",
    )
    AMOUNT_QUERY_HINTS = ("how much", "amount", "total", "spend", "spent", "spending")
    ADVICE_OR_REASON_KEYWORDS = (
        "why",
        "explain",
        "reason",
        "because",
        "analyze",
        "analysis",
        "suggest",
        "advice",
        "should",
        "recommend",
        "reduce",
        "improve",
        "plan",
        "what if",
    )

    def __init__(self, classify_with_llm=None):
        self.classify_with_llm = classify_with_llm

    def _normalize_text_for_routing(self, text):
        """Apply lightweight typo/abbreviation normalization for routing only."""
        if not isinstance(text, str):
            return ""
        normalized = text.lower().strip()
        replacements = [
            (r"\bspeend\b", "spend"),
            (r"\bspnd\b", "spend"),
            (r"\bspenging\b", "spending"),
            (r"\bspeding\b", "spending"),
            (r"\bspendng\b", "spending"),
            (r"\bexpnses?\b", "expenses"),
            (r"\btranactions\b", "transactions"),
            (r"\btransctions\b", "transactions"),
            (r"\btransections\b", "transactions"),
            (r"\btransacations\b", "transactions"),
            (r"\bcategroy\b", "category"),
            (r"\bcategry\b", "category"),
            (r"\bcatgeory\b", "category"),
            (r"\blst\b", "last"),
            (r"\banalyst\b", "analyze"),
            (r"\banlyze\b", "analyze"),
            (r"\banalyis\b", "analysis"),
            (r"\byr\b", "year"),
            (r"\bwk\b", "week"),
            (r"\bmo\b", "month"),
            (r"\b(last|previous|prior|past)\s+mo\b", r"\1 month"),
            (r"\b(previous|prior|past)\s+month\b", "last month"),
            (r"\btx\b", "transactions"),
            (r"\btxns\b", "transactions"),
            (r"\bpls\b", "please"),
            (r"\bthx\b", "thanks"),
            (r"\bwanna\b", "want to"),
            (r"\bgonna\b", "going to"),
            (r"\bur\b", "your"),
            (r"\bu\b", "you"),
        ]
        for pattern, repl in replacements:
            normalized = re.sub(pattern, repl, normalized)
        # Remove noisy punctuation/emojis while preserving date separators.
        normalized = re.sub(r"[^a-z0-9\s\-/#]", " ", normalized)
        normalized = re.sub(r"\s+", " ", normalized).strip()
        return normalized

    def _base_entities(
        self,
        *,
        metric="unknown",
        period_type="unknown",
        period_key="",
        category="",
        compare_to="",
    ):
        return {
            "metric": metric,
            "period_type": period_type,
            "period_key": period_key,
            "category": category,
            "compare_to": compare_to,
        }

    def _clarification_result(
        self,
        question,
        source="rule",
        intent="general",
        entities=None,
    ):
        return {
            "intent": intent,
            "intent_confidence": 1.0,
            "intent_candidates": [intent, "general"] if intent != "general" else ["general"],
            "intent_source": source,
            "needs_clarification": True,
            "entities": entities if isinstance(entities, dict) else self._base_entities(),
            "clarification_question": (question or "").strip()[:180],
            "response_mode": "clarification",
        }

    def _extract_period(self, text):
        return extract_period(text)

    def _extract_metric(self, text):
        if not text:
            return "unknown"
        if "income" in text or "earn" in text or "earned" in text:
            return "income"
        if "net" in text or "cash flow" in text:
            return "net"
        if "top category" in text or "highest category" in text or "most category" in text:
            return "top_category"
        if "spend" in text or "spent" in text or "spending" in text or "expense" in text:
            return "expenses"
        return "unknown"

    def _is_strong_amount_query(self, text):
        """Allow deterministic amount routing only for explicit numeric ask forms."""
        if not text:
            return False
        if "how much" in text:
            return True
        if "what did i spend" in text or "what was spent" in text:
            return True
        if "total spending" in text or "total expenses" in text:
            return True
        if re.search(r"\b(spent|spending|expenses?)\s+(this|last)\s+(month|year|week)\b", text):
            return True
        if re.search(r"\b(last\s+\d{1,3}\s+days?)\s+(spend|spent|spending|expenses?)\b", text):
            return True
        if re.search(r"\blast\s*\d{1,3}d\b", text) and (
            "spend" in text or "spent" in text or "spending" in text or "expenses" in text
        ):
            return True
        if re.search(
            r"\b(how is|how was)\s+my\s+spending\s+(this|last)\s+(month|year|week)\b", text
        ):
            return True
        if re.search(r"\bspending\s+(in|for)\s+(20\d{2}-\d{2}|20\d{2})\b", text):
            return True
        if re.search(r"\bspending\s+20\d{2}-\d{2}\b", text):
            return True
        has_total = "total" in text
        has_expense_term = (
            "spend" in text or "spent" in text or "spending" in text or "expenses" in text
        )
        return has_total and has_expense_term

    def _contains_any(self, text, keywords):
        return any(keyword in text for keyword in keywords)

    def _has_subject_signal(self, text, metric, period_type):
        if metric != "unknown" or period_type != "unknown":
            return True
        return any(
            token in text
            for token in (
                "transactions",
                "transaction",
                "category",
                "budget",
                "cash flow",
                "cost",
                "costs",
                "spending",
                "expense",
                "expenses",
                "income",
                "save",
                "saving",
                "savings",
            )
        )

    def _build_rule_result(
        self,
        *,
        intent,
        confidence,
        response_mode,
        entities,
        candidates=None,
        needs_clarification=False,
        clarification_question="",
    ):
        return {
            "intent": intent,
            "intent_confidence": confidence,
            "intent_candidates": candidates
            or ([intent, "general"] if intent != "general" else ["general"]),
            "intent_source": "rule",
            "needs_clarification": needs_clarification,
            "entities": entities,
            "clarification_question": clarification_question,
            "response_mode": response_mode,
        }

    def _rule_classify(self, message):
        # Routing contract (conservative-by-default):
        # 1) Deterministic/hybrid is allowed only when a strict rule is fully satisfied.
        # 2) If any required rule condition fails, return None so caller falls back to LLM parsing.
        # 3) If LLM output is incomplete/invalid, downstream validator should force clarification.
        text = self._normalize_text_for_routing(message or "")
        if not text:
            return self._clarification_result("Please ask a question with a topic and time period.")

        tokens = re.findall(r"[a-z0-9]+", text)
        if len(tokens) <= 1:
            if text in self.VAGUE_SINGLE_WORDS:
                return self._clarification_result(
                    "Please add context, for example: 'How much did I spend in 2026-05?'"
                )
            if len(text) < 4:
                return self._clarification_result("Please provide a more specific question.")

        period_type, period_key = self._extract_period(text)
        if period_type == "invalid":
            return self._clarification_result(
                "Please provide a valid period format, for example 2026-05 or last 30 days."
            )
        has_advice_or_reason = any(k in text for k in self.ADVICE_OR_REASON_KEYWORDS)
        has_multiple_clauses = (" and " in text) or ("," in text) or (";" in text) or ("+" in text)

        metric = self._extract_metric(text)
        base_entities = self._base_entities(
            metric=metric,
            period_type=period_type,
            period_key=period_key,
        )

        if (
            (
                self._contains_any(text, self.COMPARE_KEYWORDS)
                or "month over month" in text
                or "month-over-month" in text
                or bool(re.search(r"\bmom\b", text))
                or bool(re.search(r"\bbetween\s+20\d{2}-\d{2}\s+and\s+20\d{2}-\d{2}\b", text))
                or bool(re.search(r"\bfrom\s+20\d{2}-\d{2}\s+to\s+20\d{2}-\d{2}\b", text))
            )
            and self._has_subject_signal(text, metric, period_type)
            and not has_multiple_clauses
        ):
            if period_type == "month_range" and period_key:
                return self._build_rule_result(
                    intent="compare_periods",
                    confidence=1.0,
                    response_mode="hybrid",
                    entities=self._base_entities(
                        metric="expenses",
                        period_type=period_type,
                        period_key=period_key,
                    ),
                    candidates=["compare_periods", "general"],
                )

        if (
            self._contains_any(text, self.WHAT_IF_KEYWORDS)
            and self._has_subject_signal(text, metric, period_type)
            and not has_multiple_clauses
        ):
            return self._build_rule_result(
                intent="what_if",
                confidence=0.95,
                response_mode="llm",
                entities=base_entities,
                candidates=["what_if", "planning", "general"],
            )

        if (
            self._contains_any(text, self.PLANNING_KEYWORDS)
            and self._has_subject_signal(text, metric, period_type)
            and not has_multiple_clauses
        ):
            return self._build_rule_result(
                intent="planning",
                confidence=0.95,
                response_mode="llm",
                entities=base_entities,
                candidates=["planning", "general"],
            )

        explain_keywords = self.EXPLAIN_KEYWORDS + (
            "analyze",
            "analysis",
            "break down",
            "breakdown",
            "review",
            "trend",
            "understand",
        )
        if (
            self._contains_any(text, explain_keywords)
            and self._has_subject_signal(text, metric, period_type)
            and not has_multiple_clauses
        ):
            return self._build_rule_result(
                intent="explain",
                confidence=0.95,
                response_mode="llm",
                entities=base_entities,
                candidates=["explain", "general"],
            )

        if (
            (
                any(k in text for k in self.RECENT_TX_KEYWORDS)
                or "what did i spend on recently" in text
            )
            and not has_advice_or_reason
            and not has_multiple_clauses
        ):
            recent_period_type = period_type if period_type != "unknown" else "rolling_30d"
            recent_period_key = period_key if period_key else "rolling_30d"
            return self._build_rule_result(
                intent="recent_transactions",
                confidence=1.0,
                response_mode="deterministic",
                entities=self._base_entities(
                    metric="unknown",
                    period_type=recent_period_type,
                    period_key=recent_period_key,
                ),
                candidates=["recent_transactions", "general"],
            )

        if (
            (
                any(k in text for k in self.TOP_CATEGORY_KEYWORDS)
                or re.search(r"\b(highest|top|biggest|largest|most)\b.*\bcategory\b", text)
                or re.search(r"\bcategory\b.*\b(highest|top|biggest|largest|most)\b", text)
                or (("top" in text or "most" in text or "highest" in text) and "category" in text)
            )
            and not has_advice_or_reason
            and not has_multiple_clauses
        ):
            top_period_type = period_type if period_type != "unknown" else "rolling_30d"
            top_period_key = period_key if period_key else "rolling_30d"
            return self._build_rule_result(
                intent="top_category_lookup",
                confidence=1.0,
                response_mode="deterministic",
                entities=self._base_entities(
                    metric="top_category",
                    period_type=top_period_type,
                    period_key=top_period_key,
                ),
                candidates=["top_category_lookup", "general"],
            )

        if (
            ("which month" in text or "what month" in text)
            and ("spend" in text or "spent" in text or "spending" in text)
            and ("most" in text or "highest" in text or "max" in text)
            and not has_advice_or_reason
            and not has_multiple_clauses
        ):
            _, extracted_period_key = self._extract_period(text)
            year_key = (
                extracted_period_key
                if extracted_period_key and len(extracted_period_key) == 4
                else str(date_cls.today().year)
            )
            return self._build_rule_result(
                intent="month_overview",
                confidence=1.0,
                response_mode="deterministic",
                entities=self._base_entities(
                    metric="expenses",
                    period_type="year",
                    period_key=year_key,
                ),
                candidates=["month_overview", "general"],
            )

        amount_like = self._is_strong_amount_query(text)
        if amount_like and not has_advice_or_reason and not has_multiple_clauses:
            if metric != "expenses":
                return None
            if period_type == "unknown" or not period_key:
                return None
            if period_type not in {"rolling_30d", "rolling_days", "month", "year"}:
                return None
            return self._build_rule_result(
                intent="amount_lookup",
                confidence=1.0,
                response_mode="hybrid",
                entities=self._base_entities(
                    metric=metric,
                    period_type=period_type,
                    period_key=period_key,
                ),
                candidates=["amount_lookup", "general"],
            )

        # Uncertain: no confident deterministic rule hit.
        return None

    def _llm_classify(self, message, history=None):
        if not callable(self.classify_with_llm):
            return None

        prompt = (
            "Classify user intent for a personal finance assistant.\n"
            "Return STRICT JSON only in this exact schema:\n"
            "{"
            '"task_type":"factual_query|advice_request|causal_explanation|what_if|unknown",'
            '"intent":"...",'
            '"response_mode":"deterministic|hybrid|llm|clarification",'
            '"needs_clarification":false,'
            '"slots":{"metric":"...","period_type":"...","period_key":"...","category":"","compare_to":""},'
            '"entities":{"metric":"...","period_type":"...","period_key":"...","category":"","compare_to":""},'
            '"clarification_question":""'
            "}\n"
            "Rules:\n"
            "- Do NOT compute values.\n"
            "- Do NOT answer the question.\n"
            "- Do NOT guess missing information.\n"
            "- Use clarification when required info is missing.\n"
            f"Allowed task_type values: {sorted(self.VALID_TASK_TYPES)}\n"
            f"Allowed intents: {sorted(self.VALID_INTENTS)}\n"
            f"Allowed period_type values: {sorted(self.VALID_PERIOD_TYPES)}\n"
            f"User message:\n{message or ''}\n"
            f"Recent history:\n{json.dumps(history or [], ensure_ascii=False)}"
        )
        raw = self.classify_with_llm(
            prompt,
            generation_config={
                "temperature": 0.0,
                "maxOutputTokens": 260,
                "responseMimeType": "application/json",
            },
        )
        return json.loads(raw or "{}")

    def _task_type_to_intent(self, task_type, entities):
        metric = (entities or {}).get("metric", "unknown")
        if task_type == "factual_query":
            if metric == "top_category":
                return "top_category_lookup"
            return "amount_lookup"
        if task_type == "advice_request":
            return "planning"
        if task_type == "causal_explanation":
            return "explain"
        if task_type == "what_if":
            return "what_if"
        return "general"

    def _task_type_to_mode(self, task_type):
        if task_type == "factual_query":
            return "hybrid"
        if task_type in {"advice_request", "causal_explanation", "what_if"}:
            return "llm"
        return "clarification"

    def _is_reasonable_category(self, category):
        if not isinstance(category, str):
            return False
        value = category.strip()
        if not value or len(value) > 64:
            return False
        return re.fullmatch(r"[A-Za-z0-9 &/_\-]{2,64}", value) is not None

    def _has_compare_pair(self, entities):
        period_key = (entities.get("period_key") or "").strip()
        compare_to = (entities.get("compare_to") or "").strip()
        if compare_to:
            return True
        tokens = [x.strip() for x in re.split(r"[,\|]", period_key) if x.strip()]
        if len(tokens) >= 2:
            return True
        return bool(re.search(r"\bvs\b", period_key, flags=re.IGNORECASE))

    def _validate_llm_result(self, parsed):
        if not isinstance(parsed, dict):
            return False, "I could not understand that request. Please rephrase."

        task_type = parsed.get("task_type")
        if task_type not in self.VALID_TASK_TYPES:
            task_type = "unknown"
            parsed["task_type"] = task_type

        slots = parsed.get("slots")
        if not isinstance(slots, dict):
            slots = {}
            parsed["slots"] = slots
        intent = parsed.get("intent")
        if intent not in self.VALID_INTENTS:
            intent = self._task_type_to_intent(task_type, slots)
            parsed["intent"] = intent
        if intent not in self.VALID_INTENTS:
            return False, "Please ask in a clearer way about spending, income, category, or period."

        response_mode = parsed.get("response_mode")
        if response_mode not in self.VALID_RESPONSE_MODES:
            response_mode = self._task_type_to_mode(task_type)
            parsed["response_mode"] = response_mode
        if response_mode not in self.VALID_RESPONSE_MODES:
            return False, "I need a bit more detail to route your request safely."

        entities = parsed.get("entities")
        if isinstance(entities, dict):
            merged_entities = dict(entities)
            merged_entities.update({k: v for k, v in slots.items() if isinstance(v, str)})
            entities = merged_entities
        else:
            entities = {k: v for k, v in slots.items() if isinstance(v, str)}
        parsed["entities"] = entities

        metric = entities.get("metric")
        if metric not in self.VALID_METRICS:
            entities["metric"] = "unknown"

        period_type = entities.get("period_type")
        if period_type not in self.VALID_PERIOD_TYPES:
            entities["period_type"] = "unknown"

        for key in ("period_key", "category", "compare_to"):
            value = entities.get(key)
            entities[key] = value.strip()[:64] if isinstance(value, str) else ""

        # Validation rules required by architecture.
        if intent == "amount_lookup":
            if entities.get("metric", "unknown") == "unknown":
                return False, "Do you want expenses, income, or net amount?"
            if entities.get("period_type", "unknown") == "unknown" or not entities.get(
                "period_key"
            ):
                return (
                    False,
                    "Which time period should I use (for example, 2026-05 or last 30 days)?",
                )

        if intent == "category_spending":
            if not self._is_reasonable_category(entities.get("category", "")):
                return (
                    False,
                    "Which category should I use (for example, Food, Transport, or Subscriptions)?",
                )

        if intent == "compare_periods":
            if not self._has_compare_pair(entities):
                return (
                    False,
                    "Please provide two periods to compare, for example 2026-03 vs 2026-04.",
                )

        if entities.get("period_type", "unknown") == "unknown" and entities.get("period_key"):
            return (
                False,
                "Please provide a valid period format, for example 2026-05 or last 30 days.",
            )

        return True, ""

    def _normalize_llm_result(self, parsed):
        entities = parsed.get("entities") if isinstance(parsed.get("entities"), dict) else {}
        intent = parsed.get("intent", "general")
        task_type = parsed.get("task_type", "unknown")
        if task_type not in self.VALID_TASK_TYPES:
            task_type = "unknown"
        return {
            "intent": intent,
            "task_type": task_type,
            "intent_confidence": 0.6,
            "intent_candidates": [intent, "general"] if intent != "general" else ["general"],
            "intent_source": "llm",
            "needs_clarification": bool(parsed.get("needs_clarification", False)),
            "entities": {
                "metric": entities.get("metric", "unknown"),
                "period_type": entities.get("period_type", "unknown"),
                "period_key": entities.get("period_key", ""),
                "category": entities.get("category", ""),
                "compare_to": entities.get("compare_to", ""),
                "scope_hint": "current_scope",
            },
            "clarification_question": (parsed.get("clarification_question") or "").strip()[:180],
            "response_mode": parsed.get("response_mode", "llm"),
        }

    def classify(self, message, history=None):
        # 1) Rule-based classifier first.
        rule_result = self._rule_classify(message)
        if rule_result is not None:
            return rule_result

        # 2) LLM intent parser as fallback.
        try:
            llm_parsed = self._llm_classify(message, history=history)
        except Exception:
            llm_parsed = None

        if llm_parsed is None:
            return self._clarification_result(
                "Please clarify your request with a metric and time period.",
                source="llm",
            )

        # 3) Validation layer after LLM parsing.
        ok, clarification = self._validate_llm_result(llm_parsed)
        if not ok:
            return self._clarification_result(clarification, source="validation")

        # 4) Valid -> execution layer can consume normalized route.
        normalized = self._normalize_llm_result(llm_parsed)
        if normalized["needs_clarification"] and not normalized["clarification_question"]:
            normalized["clarification_question"] = (
                "Could you clarify the metric and time period you want to analyze?"
            )
            normalized["response_mode"] = "clarification"
        return normalized
