from __future__ import annotations

from .support import Workspace


class IndexTests(Workspace):
    def test_only_changed_transcripts_are_reindexed(self) -> None:
        self.assertEqual(self.app.index.refresh(), 2)
        self.assertEqual(self.app.index.refresh(), 0)
        self.assertEqual(self.app.index.refresh(force=True), 2)

    def test_deleted_transcripts_leave_the_index(self) -> None:
        self.app.index.refresh()
        (self.project / "bbb.jsonl").unlink()
        self.assertEqual(self.app.index.refresh(), 0)
        self.assertEqual(self.ids(), {"aaa"})

    def test_turns_count_spoken_messages_including_subagents(self) -> None:
        self.app.index.refresh()
        sessions = {row["id"]: row for row in self.app.index.sessions()}
        self.assertEqual(sessions["aaa"]["turns"], 4)
        self.assertEqual(sessions["aaa"]["title"], "Kotlin debugger spike")
        self.assertEqual(sessions["bbb"]["title"], "unrelated kotlin work")
