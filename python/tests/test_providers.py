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


if __name__ == "__main__":
    unittest.main()
