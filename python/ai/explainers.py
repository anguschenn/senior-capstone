import json

# Intent-specific prompt headers used to slightly tune response framing.
CHAT_PROMPTS = {
    "amount_lookup": (
        "Mode: Answer the requested amount directly and precisely."
    ),
    "top_category_lookup": (
        "Mode: Answer the requested top spending category directly."
    ),
    "month_overview": (
        "Mode: Summarize the key monthly spending ranking clearly."
    ),
    "compare_periods": (
        "Mode: Compare periods using explicit numbers and assumptions."
    ),
    "explain": (
        "Mode: Explain root cause clearly and directly."
    ),
    "compare": (
        "Mode: Compare options and state the trade-off."
    ),
    "what_if": (
        "Mode: Evaluate what-if impact with assumptions."
    ),
    "planning": (
        "Mode: Turn goals into concrete steps."
    ),
    "general": (
        "Mode: Give a direct financial answer."
    ),
}


def build_chat_prompt(intent, message, history, context_text):
    """Compose the strict chat prompt with rules, context, and output schema."""
    header = CHAT_PROMPTS.get(intent, CHAT_PROMPTS["general"])
    history_lines = []
    for turn in history or []:
        history_lines.append(f"{turn.get('role','user')}: {turn.get('text','')}")
    history_block = "\n".join(history_lines) if history_lines else "none"
    return (
        "You are SmartSpend, a senior personal finance assistant.\n"
        f"{header}\n"
        "Rules:\n"
        "- Use only [CONTEXT] and [HISTORY]; never invent amounts, dates, or transactions.\n"
        "- If data is insufficient, say it briefly and provide 1 best next step.\n"
        "- Always answer in English.\n"
        "- Use [HISTORY] to avoid repeating the same wording from prior assistant replies.\n"
        "- If user asks a similar question again, add at least one new angle or one different action.\n"
        "- Prioritize coaching quality: conclusion first, then evidence, then concrete actions.\n"
        "- Separate actual spending from transfers/internal movement when interpreting categories.\n"
        "- Keep advice realistic and controllable within 7-30 days.\n"
        "- Include at least one quantified suggestion with expected impact range when possible.\n"
        "- Avoid generic wording like 'spend less' unless no better option exists.\n"
        "- For month-level questions, prioritize monthly_expense_ranking and monthly_expense_trend fields.\n"
        "- For specific month/day or multi-month comparisons, prioritize month_index/day_index_recent/rankings when available.\n"
        "- Be concise and practical; default to <=120 words unless detail is requested.\n"
        "- Output STRICT JSON only; no markdown fences.\n"
        "- Avoid raw field names such as income_month/expenses_month/net_month.\n\n"
        "Output JSON schema:\n"
        '{"reply":"direct conclusion","insights":["evidence 1"],"actions":["next step 1"]}\n'
        "Constraints:\n"
        "- reply must be a short plain-text conclusion (max 280 chars).\n"
        "- insights max 3 items; include concrete numbers only when directly present in context fields.\n"
        "- actions max 3 items; each action should be specific and time-bound (e.g., this week / next 14 days).\n"
        "- At least one action should include an expected savings impact range when enough data exists.\n"
        "- If transfer categories appear, do not treat them as discretionary spending advice targets.\n"
        "- If context is insufficient, keep reply honest and include one action to improve data coverage.\n\n"
        f"[INTENT]\n{intent}\n\n"
        f"[HISTORY]\n{history_block}\n\n"
        f"[CONTEXT]\n{context_text}\n\n"
        f"[USER]\n{message}\n"
    )


def build_predict_explainer_prompt(predict_type, deterministic_payload, summary, view_mode):
    """Compose a compact prompt that rewrites deterministic forecast outputs."""
    return (
        "You are a finance explainer.\n"
        "You MUST NOT recompute values. Use deterministic forecast exactly as input.\n"
        "Return STRICT JSON only:\n"
        '{"copy":"short explanation","why":["reason1","reason2"]}\n'
        "Keep copy under 160 chars; max 3 why bullets.\n\n"
        f"[TYPE]\n{predict_type}\n\n"
        f"[VIEW_MODE]\n{view_mode}\n\n"
        f"[SUMMARY]\n{json.dumps(summary or {}, ensure_ascii=True)}\n\n"
        f"[DETERMINISTIC_FORECAST]\n{json.dumps(deterministic_payload, ensure_ascii=True)}\n"
    )
