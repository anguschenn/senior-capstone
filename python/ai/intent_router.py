class IntentRouter:
    EXPLAIN_KEYWORDS = ("why", "explain", "reason", "because")
    COMPARE_KEYWORDS = ("compare", "difference", "vs", "versus")
    WHAT_IF_KEYWORDS = ("what if", "if i", "scenario", "simulate")
    PLANNING_KEYWORDS = ("plan", "goal", "roadmap", "how should i")
    EXPLAIN_KEYWORDS_ZH = ("为什么", "原因", "解释", "为啥")
    COMPARE_KEYWORDS_ZH = ("比较", "对比", "区别", "差别")
    WHAT_IF_KEYWORDS_ZH = ("如果", "要是", "假设", "会怎样")
    PLANNING_KEYWORDS_ZH = ("计划", "目标", "怎么做", "怎么办")

    def classify(self, message, history=None):
        text = (message or "").strip().lower()
        if any(k in text for k in self.WHAT_IF_KEYWORDS) or any(
            k in text for k in self.WHAT_IF_KEYWORDS_ZH
        ):
            return "what_if"
        if any(k in text for k in self.COMPARE_KEYWORDS) or any(
            k in text for k in self.COMPARE_KEYWORDS_ZH
        ):
            return "compare"
        if any(k in text for k in self.PLANNING_KEYWORDS) or any(
            k in text for k in self.PLANNING_KEYWORDS_ZH
        ):
            return "planning"
        if any(k in text for k in self.EXPLAIN_KEYWORDS) or any(
            k in text for k in self.EXPLAIN_KEYWORDS_ZH
        ):
            return "explain"
        return "general"
