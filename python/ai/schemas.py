def build_chat_response(
    reply,
    intent,
    context_source,
    used_summary,
    tx_count_30d,
    summary_empty,
):
    return {
        "reply": reply,
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

