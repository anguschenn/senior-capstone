import json


class IntentRouter:
    VALID_INTENTS = {
        "amount_lookup",
        "top_category_lookup",
        "month_overview",
        "compare_periods",
        "general",
        "explain",
        "what_if",
        "planning",
    }
    CLARIFY_THRESHOLD = 0.55
    EXPLAIN_KEYWORDS = ("why", "explain", "reason", "because")
    COMPARE_KEYWORDS = ("compare", "difference", "vs", "versus")
    WHAT_IF_KEYWORDS = ("what if", "if i", "scenario", "simulate")
    PLANNING_KEYWORDS = ("plan", "goal", "roadmap", "how should i")
    VALID_RESPONSE_MODES = {"deterministic", "llm", "hybrid", "clarification"}

    def __init__(self, classify_with_llm=None):
        self.classify_with_llm = classify_with_llm

    def _rule_classify(self, message):
        text = (message or "").strip().lower()
        if ("how much" in text or "amount" in text) and (
            "spend" in text or "spent" in text or "spending" in text
        ):
            return "amount_lookup"
        if ("category" in text or "categories" in text) and (
            "top" in text or "most" in text or "highest" in text
        ):
            return "top_category_lookup"
        if ("which month" in text or "which months" in text) and (
            "spend" in text or "spent" in text or "spending" in text
        ):
            return "month_overview"
        if any(k in text for k in self.WHAT_IF_KEYWORDS):
            return "what_if"
        if any(k in text for k in self.COMPARE_KEYWORDS):
            return "compare_periods"
        if any(k in text for k in self.PLANNING_KEYWORDS):
            return "planning"
        if any(k in text for k in self.EXPLAIN_KEYWORDS):
            return "explain"
        return "general"

    def _llm_classify(self, message, history=None):
        if not callable(self.classify_with_llm):
            return None
        prompt = (
            "Classify user intent for a personal finance assistant.\n"
            "Return STRICT JSON only with keys:\n"
            "intent, confidence, intent_candidates, entities, needs_clarification, clarification_question, response_mode.\n"
            "No markdown, no extra keys.\n"
            "intent must be one of:\n"
            '["amount_lookup","top_category_lookup","month_overview","compare_periods","general","explain","what_if","planning"].\n'
            "confidence must be a number in [0,1].\n"
            "intent_candidates must be up to 3 intents sorted by likelihood.\n"
            "entities must be an object with keys:\n"
            "metric, period_type, period_key, scope_hint.\n"
            "metric must be one of: expenses, income, net, top_category, unknown.\n"
            "period_type must be one of: day, month, year, rolling_30d, unknown.\n"
            "response_mode must be one of: deterministic, llm, hybrid, clarification.\n"
            "Use deterministic for factual numeric/category lookups with clear period.\n"
            "Use hybrid for factual queries needing a short explanation.\n"
            "Use clarification when period/scope is missing.\n"
            "Use llm for advisory requests (explain/planning/what-if/general).\n"
            "Use needs_clarification=true when a factual query is missing a clear period.\n"
            "If needs_clarification=true, clarification_question should ask one short specific question.\n\n"
            f"User message:\n{message or ''}\n\n"
            f"Recent history:\n{json.dumps(history or [], ensure_ascii=False)}"
        )
        raw = self.classify_with_llm(
            prompt,
            generation_config={
                "temperature": 0.0,
                "maxOutputTokens": 220,
                "responseMimeType": "application/json",
            },
        )
        parsed = json.loads(raw or "{}")
        intent = parsed.get("intent")
        if intent not in self.VALID_INTENTS:
            return None
        confidence = parsed.get("confidence", 0.0)
        try:
            confidence = max(0.0, min(float(confidence), 1.0))
        except Exception:
            confidence = 0.0
        raw_candidates = parsed.get("intent_candidates")
        candidates = []
        if isinstance(raw_candidates, list):
            for item in raw_candidates:
                if item in self.VALID_INTENTS and item not in candidates:
                    candidates.append(item)
                if len(candidates) >= 3:
                    break
        if intent not in candidates:
            candidates.insert(0, intent)
        entities = parsed.get("entities")
        if not isinstance(entities, dict):
            entities = {}
        metric = entities.get("metric")
        if metric not in ("expenses", "income", "net", "top_category", "unknown"):
            metric = "unknown"
        period_type = entities.get("period_type")
        if period_type not in ("day", "month", "year", "rolling_30d", "unknown"):
            period_type = "unknown"
        period_key = entities.get("period_key")
        if not isinstance(period_key, str):
            period_key = ""
        scope_hint = entities.get("scope_hint")
        if not isinstance(scope_hint, str) or not scope_hint.strip():
            scope_hint = "current_scope"
        needs_clarification = bool(parsed.get("needs_clarification", confidence < self.CLARIFY_THRESHOLD))
        clarification_question = parsed.get("clarification_question")
        if not isinstance(clarification_question, str):
            clarification_question = ""
        clarification_question = clarification_question.strip()[:180]
        response_mode = parsed.get("response_mode")
        if not isinstance(response_mode, str) or response_mode not in self.VALID_RESPONSE_MODES:
            response_mode = ""
        return {
            "intent": intent,
            "intent_confidence": confidence,
            "intent_candidates": candidates[:3],
            "intent_source": "llm",
            "needs_clarification": needs_clarification,
            "entities": {
                "metric": metric,
                "period_type": period_type,
                "period_key": period_key.strip()[:24],
                "scope_hint": scope_hint.strip()[:32],
            },
            "clarification_question": clarification_question,
            "response_mode": response_mode,
        }

    def classify(self, message, history=None):
        try:
            llm_result = self._llm_classify(message, history=history)
            if llm_result:
                return llm_result
        except Exception:
            pass
        intent = self._rule_classify(message)
        return {
            "intent": intent,
            "intent_confidence": 0.45 if intent != "general" else 0.35,
            "intent_candidates": [intent, "general"] if intent != "general" else ["general"],
            "intent_source": "rule",
            "needs_clarification": intent == "general",
            "entities": {
                "metric": "unknown",
                "period_type": "unknown",
                "period_key": "",
                "scope_hint": "current_scope",
            },
            "clarification_question": "",
            "response_mode": "",
        }
