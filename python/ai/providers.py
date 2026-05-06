import json
import urllib.request
import urllib.error

from config import (
    LLM_PROVIDER,
    LLM_MODEL,
    OPENROUTER_API_KEY,
)

# from config import OLLAMA_HOST, OLLAMA_MODEL

_DEFAULT_TIMEOUT_SECONDS = 60


def _generate_openrouter_reply(prompt, generation_config=None):
    """
    Call OpenRouter chat completions endpoint and return plain text response.
    """

    if not OPENROUTER_API_KEY:
        raise RuntimeError("OPENROUTER_API_KEY not configured")

    endpoint = "https://openrouter.ai/api/v1/chat/completions"

    body = {
        "model": LLM_MODEL,
        "messages": [
            {
                "role": "user",
                "content": prompt,
            }
        ],
        "temperature": 0.2,
    }

    if isinstance(generation_config, dict):
        if "temperature" in generation_config:
            body["temperature"] = float(generation_config["temperature"])

        max_tokens = (
            generation_config.get("maxOutputTokens")
            or generation_config.get("max_tokens")
        )

        if max_tokens:
            body["max_tokens"] = int(max_tokens)

    req = urllib.request.Request(
        endpoint,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {OPENROUTER_API_KEY}",
            "HTTP-Referer": "http://localhost",   # Required by OpenRouter
            "X-Title": "Finance Chatbot App",     # Optional app name
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(
            req,
            timeout=_DEFAULT_TIMEOUT_SECONDS
        ) as response:
            raw = response.read().decode("utf-8")
            parsed = json.loads(raw)

    except urllib.error.HTTPError as e:
        error_body = e.read().decode()
        raise RuntimeError(
            f"OpenRouter HTTP Error {e.code}: {error_body}"
        )

    except Exception as e:
        raise RuntimeError(
            f"OpenRouter request failed: {str(e)}"
        )

    try:
        text = parsed["choices"][0]["message"]["content"]
    except Exception:
        raise RuntimeError(
            f"Malformed OpenRouter response: {parsed}"
        )

    if not isinstance(text, str) or not text.strip():
        raise RuntimeError("OpenRouter returned blank reply")

    return text.strip()


def generate_llm_reply(prompt, generation_config=None):
    """
    Public provider hook used by chat/predict services.
    """

    if LLM_PROVIDER == "openrouter":
        return _generate_openrouter_reply(
            prompt,
            generation_config=generation_config
        )

    raise RuntimeError(
        f"Unsupported LLM_PROVIDER: {LLM_PROVIDER}"
    )


def ping_llm():
    """
    Lightweight health check to validate model connectivity.
    """

    reply = generate_llm_reply("Reply with exactly: pong")

    return {
        "ok": True,
        "model": LLM_MODEL,
        "provider": LLM_PROVIDER,
        "reply_preview": reply[:80],
    }
'''
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
'''
