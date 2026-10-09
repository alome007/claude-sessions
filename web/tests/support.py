from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from claude_sessions.app import App
from claude_sessions.config import Paths


def record(**fields: object) -> str:
    return json.dumps(fields, separators=(",", ":")) + "\n"


def wrote_plan(when: str, plan: str = "alpha") -> str:
    tool = {"type": "tool_use", "name": "Write", "input": {"file_path": f"/home/u/.claude/plans/{plan}.md"}}
    return record(type="assistant", timestamp=when, message={"content": [tool]})


class Workspace(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.paths = Paths.under(Path(temporary.name))
        self.project = self.paths.projects / "-tmp-demo"
        (self.project / "aaa" / "subagents").mkdir(parents=True)
        (self.project / "aaa.jsonl").write_text(
            record(type="ai-title", aiTitle="Kotlin debugger spike")
            + record(type="user", timestamp="2026-09-14T10:00:00Z", cwd="/tmp/demo", gitBranch="stage",
                     message={"content": "how do I attach the kotlin debugger <system-reminder>hidden memo</system-reminder>"})
            + record(type="assistant", timestamp="2026-09-14T10:01:00Z", cwd="/tmp/demo", gitBranch="stage",
                     message={"content": [{"type": "text", "text": "Use JDI to attach."},
                                          {"type": "tool_use", "name": "Bash", "input": {"command": "buried"}}]})
            + record(type="user", timestamp="2026-09-14T10:02:00Z",
                     message={"content": [{"type": "tool_result", "content": "unspoken output"}]})
            + wrote_plan("2026-09-14T10:04:00Z")
            + record(type="user", timestamp="2026-09-16T08:00:00Z", message={"content": "unrelated chatter"}))
        (self.project / "aaa" / "subagents" / "agent-1.jsonl").write_text(
            record(type="assistant", timestamp="2026-09-14T10:03:00Z",
                   message={"content": [{"type": "text", "text": "subagent said pangolin"}]}))
        (self.project / "bbb.jsonl").write_text(
            record(type="user", timestamp="2026-09-15T09:00:00Z", cwd="/other", gitBranch="main",
                   message={"content": "unrelated kotlin work"})
            + wrote_plan("2026-09-15T09:30:00Z"))
        self.app = App(self.paths)

    def add_worktree_session(self) -> None:
        (self.project / "ccc.jsonl").write_text(
            record(type="user", timestamp="2026-09-17T09:00:00Z", cwd="/tmp/demo/.claude/worktrees/wt",
                   gitBranch="wt", message={"content": "worktree chat"}))

    def add_plans(self) -> None:
        self.paths.plans.mkdir()
        (self.paths.plans / "alpha.md").write_text("# Alpha plan\n\nkotlin body\n")
        (self.paths.plans / "beta.md").write_text("no heading here\n")

    def ids(self, **filters: str) -> set[str]:
        self.app.index.refresh()
        return {row["id"] for row in self.app.search(filters)["rows"]}
