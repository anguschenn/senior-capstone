def build_chat_response(
    reply,
    insights,
    actions,
    confidence,
    citations,
    intent,
    context_source,
    used_summary,
    tx_count_30d,
    summary_empty,
):
    """Normalize chat payload shape returned to Flutter clients."""
    return {
        "reply": reply,
        "insights": (insights or [])[:3],
        "actions": (actions or [])[:3],
        "confidence": max(0.0, min(float(confidence), 1.0)),
        "citations": (citations or [])[:3],
        "intent": intent,
        "context_source": context_source,
        "used_summary": bool(used_summary),
        "summary_meta": {
            "tx_count_30d": int(tx_count_30d),
            "summary_empty": bool(summary_empty),
        },
    }


def build_predict_response(
    predict_type,
    forecast,
    copy,
    why,
    alerts,
    next_actions,
    confidence,
    fallback_used,
):
    """Normalize predict/budget payload shape returned to Flutter clients."""
    return {
        "type": predict_type,
        "forecast": forecast or {},
        "copy": copy,
        "why": (why or [])[:3],
        "alerts": (alerts or [])[:5],
        "next_actions": (next_actions or [])[:5],
        "confidence": max(0.0, min(float(confidence), 1.0)),
        "fallback_used": bool(fallback_used),
    }
