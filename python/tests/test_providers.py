import json
import unittest
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

        def fake_urlopen(req, timeout=None, **_kwargs):
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

        def fake_urlopen(req, timeout=None, **_kwargs):
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


class OpenRouterRequestTests(unittest.TestCase):
    def _run(self, fail_first_with=None):
        sent = []

        def fake_urlopen(req, timeout=None, **_kwargs):
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


if __name__ == "__main__":
    unittest.main()
