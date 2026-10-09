from __future__ import annotations

import http.client
import json
import threading
import unittest
from http.server import HTTPServer

from claude_sessions.server.handler import handler_for
from claude_sessions.server.security import allowed

from .support import Workspace


class SecurityTests(unittest.TestCase):
    def test_only_local_pages_may_read(self) -> None:
        self.assertTrue(allowed("localhost:8787", None, False, 8787))
        self.assertFalse(allowed("evil.test:8787", None, False, 8787))

    def test_only_this_page_may_write(self) -> None:
        self.assertTrue(allowed("127.0.0.1:8787", "http://127.0.0.1:8787", True, 8787))
        self.assertFalse(allowed("localhost:8787", "http://evil.test", True, 8787))
        self.assertFalse(allowed("localhost:8787", None, True, 8787))


class ServerTests(Workspace):
    def setUp(self) -> None:
        super().setUp()
        self.server = HTTPServer(("127.0.0.1", 0), handler_for(self.app))
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def request(self, method: str, path: str, body: object = None, headers: dict | None = None) -> tuple[int, str, bytes]:
        connection = http.client.HTTPConnection("127.0.0.1", self.port)
        self.addCleanup(connection.close)
        payload = None if body is None else json.dumps(body).encode()
        connection.request(method, path, payload, headers or {})
        response = connection.getresponse()
        return response.status, response.getheader("Content-Type"), response.read()

    def test_the_page_and_its_assets_are_served(self) -> None:
        status, kind, page = self.request("GET", "/")
        self.assertEqual((status, kind), (200, "text/html; charset=utf-8"))
        self.assertIn(b'<script type="module" src="/static/js/app.js">', page)
        self.assertEqual(self.request("GET", "/static/js/app.js")[:2], (200, "text/javascript; charset=utf-8"))
        self.assertEqual(self.request("GET", "/static/styles.css")[:2], (200, "text/css; charset=utf-8"))

    def test_files_outside_the_static_folder_are_not_served(self) -> None:
        self.assertEqual(self.request("GET", "/static/../app.py")[0], 404)
        self.assertEqual(self.request("GET", "/static/nothing.js")[0], 404)

    def test_search_returns_sessions(self) -> None:
        status, _, body = self.request("GET", "/api/query?q=kotlin")
        self.assertEqual(status, 200)
        self.assertEqual({row["id"] for row in json.loads(body)["rows"]}, {"aaa", "bbb"})

    def test_other_hosts_and_sites_are_refused(self) -> None:
        self.assertEqual(self.request("GET", "/api/facets", headers={"Host": "evil.test"})[0], 403)
        origin = {"Origin": "http://evil.test", "Content-Type": "application/json"}
        self.assertEqual(self.request("POST", "/api/rebuild", {}, origin)[0], 403)

    def test_errors_come_back_as_json(self) -> None:
        local = {"Origin": f"http://127.0.0.1:{self.port}", "Content-Type": "application/json"}
        status, _, body = self.request("POST", "/api/plan", {"id": "missing"}, local)
        self.assertEqual((status, json.loads(body)), (400, {"error": "No plan named 'missing'"}))
        self.assertEqual(self.request("POST", "/api/nowhere", {}, local)[0], 404)
