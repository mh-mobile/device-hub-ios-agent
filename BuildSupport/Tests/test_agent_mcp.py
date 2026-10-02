"""The agent MCP script must send its bearer token only to the configured URL."""

from __future__ import annotations

import http.server
import importlib.util
import os
import threading
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "Tools/agent-mcp/device_hub_mcp.py"


def _load():
    spec = importlib.util.spec_from_file_location("device_hub_mcp", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class _Recorder(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        self.server.requests.append((self.path, self.headers.get("Authorization")))
        if self.path == "/screen":
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/elsewhere")
            self.end_headers()
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"{}")

    def log_message(self, *_):
        pass


class _Server:
    def __enter__(self):
        self.server = http.server.HTTPServer(("127.0.0.1", 0), _Recorder)
        self.server.requests = []
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return self.server

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()


class AgentMCPTests(unittest.TestCase):
    def test_redirect_is_an_error_and_is_not_followed(self):
        mcp = _load()
        with _Server() as server:
            mcp.URL = f"http://127.0.0.1:{server.server_port}"
            mcp.TOKEN = "secret-token-value"
            with self.assertRaises(RuntimeError):
                mcp.http("GET", "/screen", timeout=5)
        self.assertEqual([path for path, _ in server.requests], ["/screen"])

    def test_proxy_environment_never_sees_the_token(self):
        mcp = _load()
        with _Server() as proxy:
            mcp.URL = "http://device-hub.invalid:8765"
            mcp.TOKEN = "secret-token-value"
            proxy_url = f"http://127.0.0.1:{proxy.server_port}"
            with mock.patch.dict(os.environ, {"http_proxy": proxy_url, "HTTP_PROXY": proxy_url}):
                with self.assertRaises(Exception):
                    mcp.http("GET", "/ok", timeout=5)
        self.assertEqual(proxy.requests, [])

    def test_missing_configuration_stops_before_serving(self):
        mcp = _load()
        for environment in ({}, {"DEVICE_HUB_URL": "http://ipad:8765"}, {"DEVICE_HUB_AGENT_TOKEN": "t" * 16}):
            with mock.patch.dict(os.environ, environment, clear=True):
                with self.assertRaises(SystemExit) as stopped:
                    mcp.configure()
                self.assertNotEqual(stopped.exception.code, 0)


if __name__ == "__main__":
    unittest.main()
