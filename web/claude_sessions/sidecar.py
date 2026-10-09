from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

from .fs import write_atomic


class Sidecar:
    def __init__(self, path: Path) -> None:
        self.path = path

    def read(self) -> dict:
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {}

    def write(self, meta: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(self.path, json.dumps(meta, indent=2, sort_keys=True))


def project_key(meta: dict, path: str) -> str:
    projects = meta.setdefault("projects", {})
    for key, record in projects.items():
        if record.get("path") == path:
            return key
    key = hashlib.sha256(path.encode()).hexdigest()[:16]
    projects[key] = {"name": Path(path).name, "path": path, "pinned": False}
    return key


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
