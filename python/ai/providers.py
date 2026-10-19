import contextlib
import contextvars
import json
import ssl
import time
import urllib.error
import urllib.request
from urllib.error import HTTPError

from config import (
    AI_PROVIDER,
    OLLAMA_HOST,
    OLLAMA_MODEL,
    OPENROUTER_API_KEY,
    OPENROUTER_APP_TITLE,
    OPENROUTER_BASE_URL,
    OPENROUTER_HTTP_REFERER,
    OPENROUTER_MODEL,
)

_DEFAULT_TIMEOUT_SECONDS = 60


def _https_context():
    """Verify HTTPS with certifi's CA bundle when it's installed: python.org builds of
    Python on macOS ship without system certificates, so OpenRouter calls failed there."""
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


_HTTPS_CONTEXT = _https_context()
_OPENROUTER_MAX_RETRIES = 2


# Set per request by use_provider() when the model switch is on (local testing only).
_provider_override = contextvars.ContextVar("provider_override", default="")


@contextlib.contextmanager
def use_provider(provider):
    """Use this provider ("ollama" or "openrouter") for model calls inside the block."""
    token = _provider_override.set(provider)
    try:
        yield
    finally:
        _provider_override.reset(token)


def _provider_name():
    provider = (_provider_override.get() or AI_PROVIDER or "ollama").strip().lower()
    if provider not in {"ollama", "openrouter"}:
        raise RuntimeError(f"Unsupported AI_PROVIDER: {provider}")
    return provider


def _provider_model():
    provider = _provider_name()
    return OPENROUTER_MODEL if provider == "openrouter" else OLLAMA_MODEL


def _post_ollama(endpoint, body):
    req = urllib.request.Request(
        endpoint,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=_DEFAULT_TIMEOUT_SECONDS) as response:
        return json.loads(response.read().decode("utf-8"))


def _generate_ollama_reply(prompt, generation_config=None):
    endpoint = f"{OLLAMA_HOST.rstrip('/')}/api/generate"
    body = {
        "model": OLLAMA_MODEL,
        "prompt": prompt,
        "stream": False,
        # Thinking models (qwen3.5) otherwise reason for about a minute before a one-line
        # answer; models without thinking ignore this.
        "think": False,
    }
    # Ollama reads sampling settings only from "options"; top-level temperature and
    # num_predict are ignored, which made the same question route differently each time.
    options = {}
    if isinstance(generation_config, dict):
        if "temperature" in generation_config:
            options["temperature"] = float(generation_config.get("temperature") or 0.0)
        max_tokens = generation_config.get("maxOutputTokens") or generation_config.get("max_tokens")
        if max_tokens:
            options["num_predict"] = int(max_tokens)
        if generation_config.get("responseMimeType") == "application/json":
            body["format"] = "json"
    if options:
        body["options"] = options

    try:
        parsed = _post_ollama(endpoint, body)
    except urllib.error.HTTPError as exc:
        if exc.code != 501 or "format" not in body:
            raise
        # Some models (qwen3.5 on Ollama's MLX engine) can't do structured output; the
        # prompt still asks for JSON and the callers parse it leniently.
        body.pop("format")
        parsed = _post_ollama(endpoint, body)

    text = (parsed or {}).get("response") or ""
    if not isinstance(text, str) or not text.strip():
        raise RuntimeError("Ollama returned blank reply")
    return text


def _extract_openrouter_text(parsed):
    choices = (parsed or {}).get("choices")
    if not isinstance(choices, list) or not choices:
        return ""
    message = (choices[0] or {}).get("message") or {}
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        text_parts = []
        for chunk in content:
            if isinstance(chunk, dict) and chunk.get("type") == "text":
                value = chunk.get("text")
                if isinstance(value, str) and value.strip():
                    text_parts.append(value)
        return "\n".join(text_parts).strip()
    return ""


def _generate_openrouter_reply(prompt, generation_config=None):
    if not OPENROUTER_API_KEY:
        raise RuntimeError("OPENROUTER_API_KEY is required when AI_PROVIDER=openrouter")

    endpoint = f"{OPENROUTER_BASE_URL.rstrip('/')}/chat/completions"
    body = {
        "model": OPENROUTER_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        # Reasoning models (nemotron) otherwise spend the token budget thinking and
        # return an empty answer, or put their reasoning in the reply.
        "reasoning": {"enabled": False},
    }
    if isinstance(generation_config, dict):
        if "temperature" in generation_config:
            body["temperature"] = float(generation_config.get("temperature") or 0.0)
        max_tokens = generation_config.get("maxOutputTokens") or generation_config.get("max_tokens")
        if max_tokens:
            body["max_tokens"] = int(max_tokens)

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {OPENROUTER_API_KEY}",
    }
    if OPENROUTER_HTTP_REFERER:
        headers["HTTP-Referer"] = OPENROUTER_HTTP_REFERER
    if OPENROUTER_APP_TITLE:
        headers["X-Title"] = OPENROUTER_APP_TITLE

    parsed = None
    for attempt in range(_OPENROUTER_MAX_RETRIES + 1):
        req = urllib.request.Request(
            endpoint,
            data=json.dumps(body).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(
                req, timeout=_DEFAULT_TIMEOUT_SECONDS, context=_HTTPS_CONTEXT
            ) as response:
                raw = response.read().decode("utf-8")
                parsed = json.loads(raw)
            break
        except HTTPError as error:
            if error.code == 400 and "reasoning" in body and attempt < _OPENROUTER_MAX_RETRIES:
                # "Reasoning is mandatory for this endpoint": ask again with it left on
                body.pop("reasoning")
                continue
            if error.code == 429 and attempt < _OPENROUTER_MAX_RETRIES:
                time.sleep(1.5 * (2**attempt))
                continue
            raise

    text = _extract_openrouter_text(parsed)
    if not isinstance(text, str) or not text.strip():
        raise RuntimeError("OpenRouter returned blank reply")
    return text


def generate_llm_reply(prompt, generation_config=None):
    provider = _provider_name()
    if provider == "openrouter":
        return _generate_openrouter_reply(prompt, generation_config=generation_config)
    return _generate_ollama_reply(prompt, generation_config=generation_config)


def ping_llm():
    reply = generate_llm_reply("Reply with exactly: pong")
    return {
        "ok": True,
        "model": _provider_model(),
        "provider": _provider_name(),
        "reply_preview": reply[:80],
    }


def current_llm_info():
    return {
        "provider": _provider_name(),
        "model": _provider_model(),
    }
