"""Run with the router venv: .venv/bin/python -m unittest discover -s tests -v.

Only local stub servers are used; no model download or real inference.
"""

import asyncio
import importlib.util
import json
from pathlib import Path
import threading
import time
import unittest
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import aiohappyeyeballs
import litellm
from litellm import Router

spec = importlib.util.spec_from_file_location(
    "hub_timeout", Path(__file__).resolve().parents[1] / "config/router/connect_timeout.py"
)
policy_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy_module)


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        time.sleep(0.4)  # model-loading stand-in, longer than our test connect budget
        streaming = request.get("stream", False)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if streaming else "application/json")
        if streaming:
            chunk = {"id": "test", "object": "chat.completion.chunk", "created": 0,
                     "model": "stub", "choices": [{"index": 0,
                     "delta": {"role": "assistant", "content": "OK"}, "finish_reason": None}]}
            final = {**chunk, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            raw = ("data: " + json.dumps(chunk) + "\n\ndata: " + json.dumps(final)
                   + "\n\ndata: [DONE]\n\n").encode()
        else:
            raw = json.dumps({"id": "test", "object": "chat.completion", "created": 0,
                              "model": "stub", "choices": [{"index": 0,
                              "message": {"role": "assistant", "content": "OK"},
                              "finish_reason": "stop"}]}).encode()
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


class TimeoutTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.old_callbacks = list(litellm.callbacks)
        self.policy = policy_module.ConnectTimeout()
        self.policy.seconds = 0.15  # accelerate tests, production default remains 3s
        litellm.callbacks = [self.policy]
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    async def asyncTearDown(self):
        litellm.callbacks = self.old_callbacks
        await asyncio.to_thread(self.server.shutdown)
        self.server.server_close()

    def deployment(self, url, order):
        return {"model_name": "auto", "litellm_params": {
            "model": "openai/stub", "api_key": "test", "api_base": url,
            "timeout": 10, "stream_timeout": 10, "order": order}}

    async def exercise(self, stream, offline):
        live = self.deployment(f"http://127.0.0.1:{self.server.server_port}/v1", 2)
        deployments = [live]
        if offline:
            deployments.insert(0, self.deployment("http://192.0.2.1:8080/v1", 1))
        router = Router(model_list=deployments, num_retries=0)
        original = aiohappyeyeballs.start_connection
        stalled = []

        async def connect(*args, **kwargs):
            infos = kwargs.get("addr_infos", args[0] if args else [])
            if any(info[4][0] == "192.0.2.1" for info in infos):
                stalled.append(True)
                await asyncio.sleep(30)  # simulate silently dropped TCP SYNs
            return await original(*args, **kwargs)

        started = time.monotonic()
        with patch.object(aiohappyeyeballs, "start_connection", connect):
            result = await router.acompletion(model="auto", stream=stream,
                messages=[{"role": "user", "content": "hi"}])
            if stream:
                text = ""
                async for chunk in result:
                    text += chunk.choices[0].delta.content or "" if chunk.choices else ""
            else:
                text = result.choices[0].message.content
        self.assertEqual(text, "OK")
        self.assertLess(time.monotonic() - started, 5)
        if offline:
            self.assertTrue(stalled, "test must actually exercise a stalled connection")

    async def test_slow_read_survives_short_connect_budget(self):
        await self.exercise(stream=False, offline=False)

    async def test_slow_stream_start_survives_short_connect_budget(self):
        await self.exercise(stream=True, offline=False)

    async def test_stalled_connection_fails_over(self):
        await self.exercise(stream=False, offline=True)

    async def test_stalled_connection_fails_over_for_stream(self):
        await self.exercise(stream=True, offline=True)
