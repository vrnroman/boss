"""Tests for the TTS sidecar's HTTP gate with a fake engine (no model needed): python3 -m unittest tts/test_server.py"""
import http.client
import json
import os
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(__file__))
import kokoro_server as ks  # noqa: E402


class FakeEngine:
    def __init__(self):
        self.calls = []

    def speak(self, text, voice="af_heart", speed=1.05):
        self.calls.append((text, voice))
        return b"RIFF....WAVEfake"


class GateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.engine = FakeEngine()
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), None)
        cls.port = cls.srv.server_address[1]
        cls.srv.RequestHandlerClass = ks.make_handler(cls.engine, cls.port)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def req(self, method, path, body=None, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = {"content-type": "application/json"}
        h.update(headers or {})
        c.request(method, path, body=None if body is None else json.dumps(body), headers=h)
        r = c.getresponse()
        return r.status, r.getheader("content-type"), r.read()

    def test_speaks_english(self):
        st, ct, body = self.req("POST", "/speak", {"text": "payments: green"})
        self.assertEqual(st, 200)
        self.assertEqual(ct, "audio/wav")
        self.assertTrue(body.startswith(b"RIFF"))
        self.assertIn(("payments: green", "af_heart"), self.engine.calls)

    def test_russian_is_422_so_the_app_falls_back(self):
        n = len(self.engine.calls)
        self.assertEqual(self.req("POST", "/speak", {"text": "привет", "lang": "ru"})[0], 422)
        self.assertEqual(len(self.engine.calls), n)

    def test_browser_and_rebinding_refused(self):
        n = len(self.engine.calls)
        self.assertEqual(self.req("POST", "/speak", {"text": "x"}, {"origin": "http://evil"})[0], 403)
        self.assertEqual(self.req("POST", "/speak", {"text": "x"}, {"host": "evil:80"})[0], 403)
        self.assertEqual(len(self.engine.calls), n)

    def test_bad_inputs(self):
        self.assertEqual(self.req("POST", "/speak", {"text": "  "})[0], 400)
        self.assertEqual(self.req("POST", "/speak", {"text": "x"}, {"content-type": "text/plain"})[0], 415)
        self.assertEqual(self.req("POST", "/nope", {"text": "x"})[0], 404)
        self.assertEqual(self.req("POST", "/speak", {"text": "x" * 20000})[0], 413)

    def test_unknown_voice_falls_back_to_default(self):
        self.req("POST", "/speak", {"text": "hello", "voice": "../../etc"})
        self.assertEqual(self.engine.calls[-1], ("hello", "af_heart"))

    def test_text_is_capped(self):
        self.req("POST", "/speak", {"text": "a" * 5000})
        self.assertEqual(len(self.engine.calls[-1][0]), ks.MAX_CHARS)


if __name__ == "__main__":
    unittest.main()
