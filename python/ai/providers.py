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
    ANTHROPIC_API_KEY,
    ANTHROPIC_EFFORT,
    ANTHROPIC_MODEL,
    OLLAMA_HOST,
    OLLAMA_MODEL,
    OPENROUTER_API_KEY,
    OPENROUTER_APP_TITLE,
    OPENROUTER_BASE_URL,
    OPENROUTER_HTTP_REFERER,
    OPENROUTER_MODEL,
)

# The app gives up on an answer after 30 seconds, so a model call stops at 20 and the
# question gets its rules-only answer instead of a timeout error in the app.
_DEFAULT_TIMEOUT_SECONDS = 20
# After a call times out, that provider's calls fail at once for a minute, so a question
# that would ask a slow model twice (reword, then classify) still answers before the app
# gives up. Kept per provider, so one slow model doesn't pause the others.
_SLOW_PAUSE_SECONDS = 60
_slow_until = {}
# Keep the local model loaded between questions; reloading it adds seconds to the next one.
_OLLAMA_KEEP_ALIVE = "30m"
# Set by answer_within(): when the current request's model calls must be done.
_deadline = contextvars.ContextVar("model_deadline", default=0.0)
# A call with less time than this left isn't started; it couldn't finish anyway.
_MIN_CALL_SECONDS = 3


@contextlib.contextmanager
def answer_within(seconds):
    """Model calls inside the block share one time budget. One chat question can call the
    model three times (reword, classify, advice), so 20 seconds each could still run past
    the app's 30; once the budget is spent, calls fail at once and the rules answer."""
    token = _deadline.set(time.monotonic() + seconds)
    try:
        yield
    finally:
        _deadline.reset(token)


def _call_timeout():
    """Seconds the next model call may take: 20, or what's left of the request's budget."""
    deadline = _deadline.get()
    if not deadline:
        return _DEFAULT_TIMEOUT_SECONDS
    left = deadline - time.monotonic()
    if left < _MIN_CALL_SECONDS:
        raise RuntimeError("This request has no time left for a model call")
    return min(_DEFAULT_TIMEOUT_SECONDS, left)


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
    """Use this provider ("ollama", "openrouter" or "anthropic") for model calls inside
    the block."""
    token = _provider_override.set(provider)
    try:
        yield
    finally:
        _provider_override.reset(token)


def _provider_name():
    provider = (_provider_override.get() or AI_PROVIDER or "ollama").strip().lower()
    if provider not in {"ollama", "openrouter", "anthropic"}:
        raise RuntimeError(f"Unsupported AI_PROVIDER: {provider}")
    return provider


def _provider_model():
    return {
        "ollama": OLLAMA_MODEL,
        "openrouter": OPENROUTER_MODEL,
        "anthropic": ANTHROPIC_MODEL,
    }[_provider_name()]


def _post_ollama(endpoint, body):
    req = urllib.request.Request(
        endpoint,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=_call_timeout()) as response:
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
        "keep_alive": _OLLAMA_KEEP_ALIVE,
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
                req, timeout=_call_timeout(), context=_HTTPS_CONTEXT
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


# Thinking counts toward max_tokens, so the small caps the prompts set for Ollama would
# cut Claude off mid-answer; the prompts themselves ask for short replies.
_ANTHROPIC_MIN_MAX_TOKENS = 4096
# Models that can re-run a declined request on another model server-side; Haiku can't,
# and sending the parameter to it fails the request.
_FALLBACK_MODEL_PREFIXES = ("claude-opus-5", "claude-fable-5", "claude-sonnet-5-5")
_anthropic_client = None


def _anthropic_messages():
    """The Claude Messages API. The SDK is imported on first use, so the other providers
    work without it; retries are off because a retry would run past the question's time."""
    global _anthropic_client
    if _anthropic_client is None:
        import anthropic

        _anthropic_client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY, max_retries=0)
    return _anthropic_client.with_options(timeout=_call_timeout()).beta.messages


def _generate_anthropic_reply(prompt, generation_config=None):
    if not ANTHROPIC_API_KEY:
        raise RuntimeError("ANTHROPIC_API_KEY is required for the Claude model")
    import anthropic

    requested = 0
    if isinstance(generation_config, dict):
        requested = int(
            generation_config.get("maxOutputTokens") or generation_config.get("max_tokens") or 0
        )
    fallback = {}
    if ANTHROPIC_MODEL.startswith(_FALLBACK_MODEL_PREFIXES):
        # A declined request is run again on the model Anthropic picks for that kind of
        # decline, inside the same call.
        fallback = {"betas": ["server-side-fallback-2026-07-01"], "fallbacks": "default"}
    try:
        response = _anthropic_messages().create(
            model=ANTHROPIC_MODEL,
            max_tokens=max(requested, _ANTHROPIC_MIN_MAX_TOKENS),
            output_config={"effort": ANTHROPIC_EFFORT},
            messages=[{"role": "user", "content": prompt}],
            **fallback,
        )
    except anthropic.APITimeoutError as error:
        raise TimeoutError("Claude didn't answer in time") from error
    if response.stop_reason == "refusal":
        raise RuntimeError("Claude declined to answer")
    text = "\n".join(block.text for block in response.content if block.type == "text").strip()
    if not text:
        raise RuntimeError("Claude returned blank reply")
    return text


def _timed_out(error):
    """Whether a urlopen error is a timeout (on connect it comes wrapped in a URLError)."""
    return isinstance(error, TimeoutError) or isinstance(
        getattr(error, "reason", None), TimeoutError
    )


def generate_llm_reply(prompt, generation_config=None):
    provider = _provider_name()
    if time.monotonic() < _slow_until.get(provider, 0.0):
        raise RuntimeError("The model timed out a moment ago; answering without it for now")
    try:
        if provider == "openrouter":
            return _generate_openrouter_reply(prompt, generation_config=generation_config)
        if provider == "anthropic":
            return _generate_anthropic_reply(prompt, generation_config=generation_config)
        return _generate_ollama_reply(prompt, generation_config=generation_config)
    except (TimeoutError, urllib.error.URLError) as error:
        if _timed_out(error):
            _slow_until[provider] = time.monotonic() + _SLOW_PAUSE_SECONDS
        raise


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
