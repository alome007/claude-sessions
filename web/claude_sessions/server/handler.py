from __future__ import annotations

import json
import subprocess
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Callable
from urllib.parse import parse_qs, urlparse

from ..app import App
from .security import allowed

STATIC = Path(__file__).parent / "static"
CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
}
SEARCH_FILTERS = ("q", "role", "project", "branch", "since", "until", "sort")
ACTIONS: dict[str, Callable[[App, dict], None]] = {
    "/api/plan": lambda app, body: app.edit_plan(body.get("id"), {k: v for k, v in body.items() if k != "id"}),
    "/api/plan/delete": lambda app, body: app.delete_plan(body.get("id")),
    "/api/plan/open": lambda app, body: app.open_plan(body.get("id")),
    "/api/session/reveal": lambda app, body: app.reveal_session(body.get("id")),
    "/api/project/archive": lambda app, body: app.set_archived(body.get("path"), body.get("archived")),
    "/api/rebuild": lambda app, body: app.rebuild(),
}


def handler_for(app: App) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        @property
        def port(self) -> int:
            return self.server.server_address[1]

        def do_GET(self) -> None:
            if not allowed(self.headers.get("Host"), self.headers.get("Origin"), False, self.port):
                self.fail(403, f"Open this page at http://localhost:{self.port}/")
                return
            route = urlparse(self.path)
            if route.path == "/api/query":
                filters = {k: v[0] for k, v in parse_qs(route.query).items() if k in SEARCH_FILTERS}
                self.reply(app.search(filters))
            elif route.path == "/api/facets":
                self.reply(app.facets())
            elif route.path == "/api/plans":
                self.reply({"plans": app.plan_list()})
            elif route.path.startswith("/static/"):
                self.static(route.path)
            else:
                self.send_file(STATIC / "index.html")

        def do_POST(self) -> None:
            if not allowed(self.headers.get("Host"), self.headers.get("Origin"), True, self.port):
                self.fail(403, "Requests from other sites are refused")
                return
            try:
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
                if not isinstance(body, dict):
                    raise ValueError("Expected a JSON object")
                action = ACTIONS.get(self.path)
                if action is None:
                    self.fail(404, f"Nothing at {self.path}")
                    return
                action(app, body)
            except ValueError as exc:
                self.fail(400, str(exc))
                return
            except (OSError, subprocess.CalledProcessError) as exc:
                self.fail(500, str(exc))
                return
            self.reply(app.snapshot())

        def static(self, route_path: str) -> None:
            file = (STATIC / route_path.removeprefix("/static/")).resolve()
            if STATIC.resolve() not in file.parents or file.suffix not in CONTENT_TYPES or not file.is_file():
                self.fail(404, f"Nothing at {route_path}")
                return
            self.send_file(file)

        def send_file(self, file: Path) -> None:
            self.send(file.read_bytes(), CONTENT_TYPES[file.suffix])

        def reply(self, data: dict) -> None:
            self.send(json.dumps(data).encode(), "application/json")

        def fail(self, status: int, message: str) -> None:
            self.send(json.dumps({"error": message}).encode(), "application/json", status)

        def send(self, body: bytes, content_type: str, status: int = 200) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args: object) -> None:
            pass

    return Handler
