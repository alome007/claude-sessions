from __future__ import annotations

from typing import Callable

from .sidecar import Sidecar, project_key

WORKTREES = "/.claude/worktrees/"


def repo_of(path: str) -> str:
    return path.split(WORKTREES)[0]


class ProjectArchive:
    def __init__(self, sidecar: Sidecar) -> None:
        self.sidecar = sidecar

    def archived(self) -> set[str]:
        records = self.sidecar.read().get("projects", {}).values()
        return {record["path"] for record in records if record.get("archived") and record.get("path")}

    def set_archived(self, path: object, archived: object, known_projects: Callable[[], list[str]]) -> None:
        if not isinstance(archived, bool):
            raise ValueError("archived must be true or false")
        if path not in known_projects():
            raise ValueError(f"Unknown project {path!r}")
        meta = self.sidecar.read()
        key = project_key(meta, path)
        meta["projects"][key]["archived"] = archived
        self.sidecar.write(meta)
