import json
import urllib.request

from config import OLLAMA_HOST, OLLAMA_MODEL


_DEFAULT_TIMEOUT_SECONDS = 60


def _generate_ollama_reply(prompt, generation_config=None):
    """Call Ollama's generate endpoint and return plain response text."""
    endpoint = f"{OLLAMA_HOST.rstrip('/')}/api/generate"
    body = {
        "model": OLLAMA_MODEL,
        "prompt": prompt,
        "stream": False,
    }
    if isinstance(generation_config, dict):
        if "temperature" in generation_config:
            body["temperature"] = float(generation_config.get("temperature") or 0.0)
        max_tokens = generation_config.get("maxOutputTokens") or generation_config.get("max_tokens")
        if max_tokens:
            body["num_predict"] = int(max_tokens)

    req = urllib.request.Request(
        endpoint,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=_DEFAULT_TIMEOUT_SECONDS) as response:
        raw = response.read().decode("utf-8")
        parsed = json.loads(raw)

    # We only expose the final text response to service layers.
    text = (parsed or {}).get("response") or ""
    if not isinstance(text, str) or not text.strip():
        raise RuntimeError("Ollama returned blank reply")
    return text


def generate_llm_reply(prompt, generation_config=None):
    """Public provider hook used by chat/predict services."""
    return _generate_ollama_reply(prompt, generation_config=generation_config)


def ping_llm():
    """Lightweight health check to validate model connectivity and response."""
    reply = generate_llm_reply("Reply with exactly: pong")
    return {
        "ok": True,
        "model": OLLAMA_MODEL,
        "provider": "ollama",
        "reply_preview": reply[:80],
    }
