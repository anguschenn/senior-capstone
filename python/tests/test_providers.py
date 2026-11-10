import json
import unittest
from types import SimpleNamespace
from unittest import mock

from ai import providers


class _Response:
    def __init__(self, payload):
        self._raw = json.dumps(payload).encode("utf-8")

    def read(self):
        return self._raw

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class OllamaRequestTests(unittest.TestCase):
    def _sent_body(self, generation_config):
        sent = {}

        def fake_urlopen(req, timeout=None):
            sent["body"] = json.loads(req.data.decode("utf-8"))
            return _Response({"response": '{"reply":"ok"}'})

        with mock.patch.object(providers.urllib.request, "urlopen", fake_urlopen):
            providers._generate_ollama_reply("hi", generation_config=generation_config)
        return sent["body"]

    def test_sampling_settings_go_in_options(self):
        body = self._sent_body({"temperature": 0.0, "maxOutputTokens": 260})
        self.assertEqual(body["options"], {"temperature": 0.0, "num_predict": 260})
        self.assertNotIn("temperature", body)
        self.assertNotIn("num_predict", body)

    def test_json_mime_type_asks_for_json_format(self):
        body = self._sent_body({"responseMimeType": "application/json"})
        self.assertEqual(body["format"], "json")

    def test_no_config_sends_plain_request(self):
        body = self._sent_body(None)
        self.assertNotIn("options", body)
        self.assertNotIn("format", body)

    def test_thinking_is_turned_off(self):
        self.assertIs(self._sent_body(None)["think"], False)

    def test_json_falls_back_when_structured_output_is_unavailable(self):
        sent = []

        def fake_urlopen(req, timeout=None):
            body = json.loads(req.data.decode("utf-8"))
            sent.append(body)
            if "format" in body:
                raise providers.urllib.error.HTTPError(
                    req.full_url, 501, "Not Implemented", {}, None
                )
            return _Response({"response": '{"reply":"ok"}'})

        with mock.patch.object(providers.urllib.request, "urlopen", fake_urlopen):
            reply = providers._generate_ollama_reply(
                "hi", generation_config={"responseMimeType": "application/json"}
            )
        self.assertEqual(reply, '{"reply":"ok"}')
        self.assertEqual([("format" in body) for body in sent], [True, False])

    def test_the_model_stays_loaded_between_questions(self):
        self.assertEqual(self._sent_body(None)["keep_alive"], "30m")


class SlowModelTests(unittest.TestCase):
    def setUp(self):
        for patch in (
            mock.patch.object(providers, "AI_PROVIDER", "ollama"),
            mock.patch.object(providers, "_slow_until", {}),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def _ask(self, error):
        calls = []

        def fake_urlopen(req, timeout=None, **_kwargs):
            calls.append(timeout)
            raise error

        with mock.patch.object(providers.urllib.request, "urlopen", fake_urlopen):
            for _ in range(2):
                with self.assertRaises(Exception):
                    providers.generate_llm_reply("hi")
        return calls

    def test_a_timeout_skips_the_model_for_a_while(self):
        # the app gives up after 30 seconds, so the next call answers without the model
        self.assertEqual(self._ask(TimeoutError("timed out")), [20])

    def test_a_timeout_while_connecting_counts_too(self):
        error = providers.urllib.error.URLError(TimeoutError("timed out"))
        self.assertEqual(self._ask(error), [20])

    def test_other_errors_keep_asking_the_model(self):
        error = providers.urllib.error.URLError(ConnectionRefusedError("refused"))
        self.assertEqual(self._ask(error), [20, 20])

    def test_a_question_s_model_calls_share_one_budget(self):
        # Each call answers just under its limit, so no single call times out; together
        # three of them would still run past the app's 30 seconds.
        now = [1000.0]
        calls = []

        def fake_urlopen(req, timeout=None, **_kwargs):
            calls.append(round(timeout))
            now[0] += timeout - 1
            return _Response({"response": "ok"})

        with (
            mock.patch.object(providers.time, "monotonic", lambda: now[0]),
            mock.patch.object(providers.urllib.request, "urlopen", fake_urlopen),
            providers.answer_within(25),
        ):
            self.assertEqual(providers.generate_llm_reply("reword"), "ok")
            self.assertEqual(providers.generate_llm_reply("classify"), "ok")
            with self.assertRaises(RuntimeError):
                providers.generate_llm_reply("advice")
        self.assertEqual(calls, [20, 6])
        self.assertLess(now[0] - 1000.0, 25)
        # outside a request a call gets its full 20 seconds again
        with mock.patch.object(providers.urllib.request, "urlopen", fake_urlopen):
            providers.generate_llm_reply("hi")
        self.assertEqual(calls[-1], 20)


class OpenRouterRequestTests(unittest.TestCase):
    def _run(self, fail_first_with=None):
        sent = []

        def fake_urlopen(req, timeout=None):
            body = json.loads(req.data.decode("utf-8"))
            sent.append(body)
            if fail_first_with and len(sent) == 1:
                raise providers.urllib.error.HTTPError(
                    req.full_url, fail_first_with, "error", {}, None
                )
            return _Response({"choices": [{"message": {"content": "ok"}}]})

        with (
            mock.patch.object(providers, "OPENROUTER_API_KEY", "test-key"),
            mock.patch.object(providers.urllib.request, "urlopen", fake_urlopen),
        ):
            reply = providers._generate_openrouter_reply("hi")
        return reply, sent

    def test_reasoning_is_turned_off(self):
        reply, sent = self._run()
        self.assertEqual(reply, "ok")
        self.assertEqual(sent[0]["reasoning"], {"enabled": False})

    def test_retries_with_reasoning_when_a_model_requires_it(self):
        reply, sent = self._run(fail_first_with=400)
        self.assertEqual(reply, "ok")
        self.assertEqual(len(sent), 2)
        self.assertNotIn("reasoning", sent[1])


class _FakeClaude:
    """Stands in for anthropic.Anthropic: records the timeout and the request."""

    def __init__(self, reply="ok", stop_reason="end_turn", error=None):
        self.timeouts = []
        self.requests = []
        self._reply, self._stop_reason, self._error = reply, stop_reason, error
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create))

    def with_options(self, timeout=None):
        self.timeouts.append(timeout)
        return self

    def _create(self, **request):
        self.requests.append(request)
        if self._error:
            raise self._error
        return SimpleNamespace(
            stop_reason=self._stop_reason,
            content=[
                SimpleNamespace(type="thinking", thinking=""),
                SimpleNamespace(type="text", text=self._reply),
            ],
        )


class ClaudeRequestTests(unittest.TestCase):
    def setUp(self):
        for patch in (
            mock.patch.object(providers, "AI_PROVIDER", "anthropic"),
            mock.patch.object(providers, "ANTHROPIC_API_KEY", "test-key"),
            mock.patch.object(providers, "_slow_until", {}),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def _ask(self, client, generation_config=None):
        with mock.patch.object(providers, "_anthropic_client", client):
            return providers.generate_llm_reply("hi", generation_config=generation_config)

    def test_request_uses_the_configured_model_with_room_to_think(self):
        client = _FakeClaude()
        reply = self._ask(client, {"temperature": 0.0, "maxOutputTokens": 260})
        self.assertEqual(reply, "ok")
        (request,) = client.requests
        self.assertEqual(request["model"], providers.ANTHROPIC_MODEL)
        self.assertEqual(request["max_tokens"], 4096)
        self.assertEqual(request["output_config"], {"effort": providers.ANTHROPIC_EFFORT})
        self.assertEqual(request["messages"], [{"role": "user", "content": "hi"}])
        # current Claude models reject sampling settings
        self.assertNotIn("temperature", request)

    def test_only_models_with_server_side_fallback_ask_for_it(self):
        for model, expected in (
            ("claude-haiku-5-5", False),
            ("claude-sonnet-5-5", True),
            ("claude-opus-5-5", True),
        ):
            with self.subTest(model=model), mock.patch.object(providers, "ANTHROPIC_MODEL", model):
                client = _FakeClaude()
                self._ask(client)
                (request,) = client.requests
                self.assertEqual(request["model"], model)
                self.assertEqual(request.get("fallbacks"), "default" if expected else None)
                self.assertEqual(
                    request.get("betas"),
                    ["server-side-fallback-2026-07-01"] if expected else None,
                )

    def test_a_call_gets_what_is_left_of_the_question_s_time(self):
        client = _FakeClaude()
        now = [1000.0]
        with (
            mock.patch.object(providers.time, "monotonic", lambda: now[0]),
            providers.answer_within(25),
        ):
            now[0] += 15
            self._ask(client)
        self.assertEqual(client.timeouts, [10])

    def test_a_refusal_falls_back_to_the_rules_answer(self):
        with self.assertRaises(RuntimeError):
            self._ask(_FakeClaude(reply="", stop_reason="refusal"))

    def test_a_timeout_skips_the_model_for_a_while(self):
        import anthropic
        import httpx2

        request = httpx2.Request("POST", "https://api.anthropic.com/v1/messages")
        client = _FakeClaude(error=anthropic.APITimeoutError(request=request))
        with self.assertRaises(TimeoutError):
            self._ask(client)
        with self.assertRaises(RuntimeError):
            self._ask(client)
        self.assertEqual(len(client.requests), 1)

    def test_a_slow_local_model_does_not_pause_claude(self):
        # the app's model switch can pick Claude right after the local model timed out
        providers._slow_until["ollama"] = providers.time.monotonic() + 60
        self.assertEqual(self._ask(_FakeClaude()), "ok")

    def test_no_key_means_no_call(self):
        client = _FakeClaude()
        with (
            mock.patch.object(providers, "ANTHROPIC_API_KEY", None),
            self.assertRaises(RuntimeError),
        ):
            self._ask(client)
        self.assertEqual(client.requests, [])

    def test_health_reports_claude(self):
        self.assertEqual(
            providers.current_llm_info(),
            {"provider": "anthropic", "model": providers.ANTHROPIC_MODEL},
        )


if __name__ == "__main__":
    unittest.main()
