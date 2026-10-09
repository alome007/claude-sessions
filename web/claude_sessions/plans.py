from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .fs import write_atomic
from .index import SessionIndex
from .projects import repo_of
from .sidecar import Sidecar, now_iso, project_key
from .transcripts import group_by_session, timestamp

STATUSES = ("", "active", "completed")
EDITABLE = {"body", "project", "status", "pinned", "tags", "progress"}


@dataclass
class Plan:
    id: str
    title: str
    body: str
    project: str
    status: str
    pinned: bool
    tags: list[str]
    progress: float
    modified: float
    size: int


class PlanStore:
    def __init__(self, folder: Path, sidecar: Sidecar, index: SessionIndex) -> None:
        self.folder = folder
        self.sidecar = sidecar
        self.index = index
        self._scanned: set[str] = set()

    def load(self) -> list[Plan]:
        meta = self.sidecar.read()
        entries = meta.get("plans", {})
        projects = meta.get("projects", {})
        overrides = meta.get("planProjectOverrides", {})
        scanned = meta.get("projectScan", {}).get("assignments", {})
        plans = []
        for path in self.folder.glob("*.md"):
            body = path.read_text(encoding="utf-8", errors="replace")
            info = path.stat()
            entry = entries.get(path.stem, {})
            key = overrides.get(path.stem) or scanned.get(path.stem)
            plans.append(Plan(
                id=path.stem,
                title=next((line[2:] for line in body.splitlines() if line.startswith("# ")), path.stem),
                body=body,
                project=repo_of(projects.get(key, {}).get("path", "")),
                status=entry.get("status", ""),
                pinned=entry.get("pinned", False),
                tags=entry.get("tags", []),
                progress=entry.get("readingProgress", 0),
                modified=info.st_mtime,
                size=info.st_size,
            ))
        plans.sort(key=lambda plan: (not plan.pinned, -plan.modified))
        return plans

    def path(self, plan_id: object) -> Path:
        if not isinstance(plan_id, str):
            raise ValueError("A plan id is required")
        path = self.folder / f"{plan_id}.md"
        if path.parent != self.folder or not path.is_file():
            raise ValueError(f"No plan named {plan_id!r}")
        return path

    def edit(self, plan_id: object, change: dict, known_projects: Callable[[], list[str]]) -> None:
        path = self.path(plan_id)
        entry = _validated_entry(change, known_projects)
        if "body" in change:
            write_atomic(path, change["body"])
        if not entry and "project" not in change:
            return
        meta = self.sidecar.read()
        if "project" in change:
            meta.setdefault("planProjectOverrides", {})[plan_id] = project_key(meta, change["project"])
        if entry:
            meta.setdefault("plans", {}).setdefault(plan_id, {}).update(entry, lastReadAt=now_iso())
        self.sidecar.write(meta)

    def delete(self, plan_id: object) -> None:
        self.path(plan_id).unlink()
        meta = self.sidecar.read()
        if meta.get("plans", {}).pop(plan_id, None) is not None:
            self.sidecar.write(meta)

    def resolve_projects(self) -> None:
        missing = [plan.id for plan in self.load() if not plan.project and plan.id not in self._scanned]
        if not missing:
            return
        self._scanned.update(missing)
        self.index.refresh()
        found = self.writers_of(missing)
        if not found:
            return
        meta = self.sidecar.read()
        scan = meta.setdefault("projectScan", {})
        assignments = scan.setdefault("assignments", {})
        for plan_id, project in found.items():
            assignments[plan_id] = project_key(meta, project)
        scan["scannedAt"] = now_iso()
        self.sidecar.write(meta)

    def writers_of(self, plan_ids: list[str]) -> dict[str, str]:
        earliest: dict[str, tuple[float, str]] = {}
        for session_id, paths in group_by_session(self.index.transcripts).items():
            for path in paths:
                blob = path.read_bytes()
                if b".claude/plans/" not in blob:
                    continue
                for line in blob.decode("utf-8", "replace").splitlines():
                    if '"name":"Write"' in line:
                        _note_writes(earliest, session_id, line, plan_ids)
        found = {}
        for plan_id, (_, session_id) in earliest.items():
            project = self.index.project_of(session_id)
            if project:
                found[plan_id] = project
        return found


def _note_writes(earliest: dict[str, tuple[float, str]], session_id: str, line: str, plan_ids: list[str]) -> None:
    for plan_id in plan_ids:
        if f".claude/plans/{plan_id}.md" not in line:
            continue
        try:
            when = timestamp(json.loads(line).get("timestamp"))
        except json.JSONDecodeError:
            continue
        if when and when < earliest.get(plan_id, (float("inf"), ""))[0]:
            earliest[plan_id] = (when, session_id)


def _validated_entry(change: dict, known_projects: Callable[[], list[str]]) -> dict:
    unknown = set(change) - EDITABLE
    if unknown:
        raise ValueError(f"Unknown plan fields: {', '.join(sorted(unknown))}")
    if "body" in change and not isinstance(change["body"], str):
        raise ValueError("body must be text")
    if "project" in change and change["project"] not in known_projects():
        raise ValueError(f"Unknown project {change['project']!r}")
    if "status" in change and change["status"] not in STATUSES:
        raise ValueError(f"status must be one of {STATUSES}")
    if "pinned" in change and not isinstance(change["pinned"], bool):
        raise ValueError("pinned must be true or false")
    tags = change.get("tags", [])
    if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
        raise ValueError("tags must be a list of text")
    progress = change.get("progress", 0)
    if isinstance(progress, bool) or not isinstance(progress, (int, float)) or not 0 <= progress <= 1:
        raise ValueError("progress must be a number from 0 to 1")
    entry = {key: change[key] for key in ("status", "pinned") if key in change}
    if "tags" in change:
        entry["tags"] = [tag.strip() for tag in tags if tag.strip()]
    if "progress" in change:
        entry["readingProgress"] = progress
    return entry
