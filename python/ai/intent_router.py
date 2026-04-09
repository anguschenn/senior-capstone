class IntentRouter:
    EXPLAIN_KEYWORDS = ("why", "explain", "reason", "because", "为什么", "解释")
    COMPARE_KEYWORDS = ("compare", "difference", "vs", "versus", "同比", "环比", "对比")
    WHAT_IF_KEYWORDS = ("what if", "if i", "scenario", "simulate", "假如", "如果")
    PLANNING_KEYWORDS = ("plan", "goal", "roadmap", "how should i", "预算计划", "目标")

    def classify(self, message, history=None):
        text = (message or "").strip().lower()
        if any(k in text for k in self.WHAT_IF_KEYWORDS):
            return "what_if"
        if any(k in text for k in self.COMPARE_KEYWORDS):
            return "compare"
        if any(k in text for k in self.PLANNING_KEYWORDS):
            return "planning"
        if any(k in text for k in self.EXPLAIN_KEYWORDS):
            return "explain"
        return "general"

