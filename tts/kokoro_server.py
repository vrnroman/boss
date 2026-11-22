"""Kokoro TTS sidecar for Boss: POST /speak {"text": "...", "lang": "en"} -> audio/wav.

Local only (127.0.0.1). Refuses browser requests (any Origin header) and foreign Host headers.
English goes to Kokoro (voice af_heart by default). Kokoro has no Russian voice, so lang="ru"
answers 422 and the app falls back to the macOS Milena voice.
Run: venv/bin/python tts/kokoro_server.py --models ~/Boss/tts [--port 8792]
"""
import argparse
import io
import json
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_CHARS = 1200
VOICES = {"af_heart", "af_bella", "af_nicole", "af_sarah", "bf_emma", "bf_isabella"}


def to_wav(samples, rate):
    import numpy as np

    pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2").tobytes()
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


class Engine:
    def __init__(self, models):
        from kokoro_onnx import Kokoro

        self.k = Kokoro(f"{models}/kokoro-v1.0.onnx", f"{models}/voices-v1.0.bin")
        self.lock = threading.Lock()

    def speak(self, text, voice="af_heart", speed=1.05):
        with self.lock:
            samples, rate = self.k.create(text, voice=voice, speed=speed, lang="en-us")
        return to_wav(samples, rate)


def make_handler(engine, port):
    class H(BaseHTTPRequestHandler):
        server_version = "boss-tts/1"

        def log_message(self, fmt, *args):  # quiet; the app logs
            pass

        def reply(self, code, body, ctype="application/json"):
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(code)
            self.send_header("content-type", ctype)
            self.send_header("content-length", str(len(data)))
            self.send_header("cache-control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def refused(self):
            host = self.headers.get("host", "")
            if host not in (f"127.0.0.1:{port}", f"localhost:{port}"):
                return "bad host"
            if self.headers.get("origin") is not None:
                return "browser requests are refused"
            return None

        def do_GET(self):
            why = self.refused()
            if why:
                return self.reply(403, {"error": why})
            if self.path == "/health":
                return self.reply(200, {"ok": True, "engine": "kokoro", "langs": ["en"]})
            self.reply(404, {"error": "not found"})

        def do_POST(self):
            why = self.refused()
            if why:
                return self.reply(403, {"error": why})
            if self.path != "/speak":
                return self.reply(404, {"error": "not found"})
            if not self.headers.get("content-type", "").startswith("application/json"):
                return self.reply(415, {"error": "content-type must be application/json"})
            n = int(self.headers.get("content-length") or 0)
            if n > 16384:
                return self.reply(413, {"error": "body too large"})
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
                text = str(body.get("text", "")).strip()[:MAX_CHARS]
                lang = str(body.get("lang", "en"))
                voice = str(body.get("voice", "af_heart"))
            except Exception:
                return self.reply(400, {"error": "invalid JSON"})
            if not text:
                return self.reply(400, {"error": "text is empty"})
            if lang != "en":
                return self.reply(422, {"error": "kokoro has no voice for this language"})
            if voice not in VOICES:
                voice = "af_heart"
            t0 = time.time()
            wav = engine.speak(text, voice=voice)
            self.send_response(200)
            self.send_header("content-type", "audio/wav")
            self.send_header("content-length", str(len(wav)))
            self.send_header("x-gen-ms", str(int((time.time() - t0) * 1000)))
            self.end_headers()
            self.wfile.write(wav)

    return H


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True)
    ap.add_argument("--port", type=int, default=8792)
    a = ap.parse_args()
    engine = Engine(a.models)
    engine.speak("Ready.")  # warm the model so the first real answer is fast
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(engine, a.port))
    print(f"boss-tts listening on 127.0.0.1:{a.port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
