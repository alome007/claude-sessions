from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

PORT = 8787


@dataclass(frozen=True)
class Paths:
    projects: Path
    index: Path
    plans: Path

    @property
    def sidecar(self) -> Path:
        return self.plans / ".plan-manager.json"

    @classmethod
    def under(cls, home: Path) -> Paths:
        claude = home / ".claude"
        return cls(projects=claude / "projects", index=claude / "session-index-web.db", plans=claude / "plans")
