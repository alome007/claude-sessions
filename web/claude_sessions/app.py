from __future__ import annotations

from dataclasses import asdict

from .config import Paths
from .desktop import show
from .index import SessionIndex
from .plans import PlanStore
from .projects import ProjectArchive
from .search import facets, search
from .sidecar import Sidecar
from .transcripts import find_transcript


class App:
    def __init__(self, paths: Paths) -> None:
        sidecar = Sidecar(paths.sidecar)
        self.paths = paths
        self.index = SessionIndex(paths.index, paths.projects)
        self.archive = ProjectArchive(sidecar)
        self.plans = PlanStore(paths.plans, sidecar, self.index)

    def facets(self) -> dict:
        return facets(self.index, self.archive.archived())

    def known_projects(self) -> list[str]:
        return self.facets()["projects"]

    def search(self, filters: dict[str, str]) -> dict:
        self.index.refresh()
        return {"rows": search(self.index, self.archive.archived(), **filters), "total": self.facets()["total"]}

    def plan_list(self) -> list[dict]:
        self.plans.resolve_projects()
        return [asdict(plan) for plan in self.plans.load()]

    def snapshot(self) -> dict:
        return {"plans": [asdict(plan) for plan in self.plans.load()], "facets": self.facets()}

    def edit_plan(self, plan_id: object, change: dict) -> None:
        self.plans.edit(plan_id, change, self.known_projects)

    def delete_plan(self, plan_id: object) -> None:
        self.plans.delete(plan_id)

    def open_plan(self, plan_id: object) -> None:
        show(self.plans.path(plan_id))

    def reveal_session(self, session_id: object) -> None:
        show(find_transcript(self.paths.projects, session_id), select=True)

    def set_archived(self, path: object, archived: object) -> None:
        self.archive.set_archived(path, archived, self.known_projects)

    def rebuild(self) -> None:
        self.index.refresh(force=True)
