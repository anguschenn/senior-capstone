import json


CHAT_PROMPTS = {
    "explain": (
        "You are a finance assistant. Focus on root causes and drivers. "
        "Give a concise direct explanation."
    ),
    "compare": (
        "You are a finance assistant. Focus on key differences, deltas, and trade-offs."
    ),
    "what_if": (
        "You are a finance assistant. Simulate scenario outcomes based on provided data only."
    ),
    "planning": (
        "You are a finance assistant. Provide an actionable goal breakdown with concrete steps."
    ),
    "general": (
        "You are a finance assistant. Answer clearly and concisely using provided context only."
    ),
}


def build_chat_prompt(intent, message, history, context_text):
    header = CHAT_PROMPTS.get(intent, CHAT_PROMPTS["general"])
    history_lines = []
    for turn in history or []:
        history_lines.append(f"{turn.get('role','user')}: {turn.get('text','')}")
    history_block = "\n".join(history_lines) if history_lines else "none"
    return (
        f"{header}\n"
        "Do not fabricate data. If context is sparse, say it briefly and still provide best-effort guidance.\n\n"
        f"[INTENT]\n{intent}\n\n"
        f"[HISTORY]\n{history_block}\n\n"
        f"[CONTEXT]\n{context_text}\n\n"
        f"[USER]\n{message}\n"
    )


def build_predict_explainer_prompt(predict_type, deterministic_payload, summary, view_mode):
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

