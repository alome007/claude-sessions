from __future__ import annotations

import unittest

from claude_sessions.transcripts import find_transcript, group_by_session, read_conversation, spoken_texts, timestamp

from .support import Workspace


class SpokenTextTests(unittest.TestCase):
    def test_injected_context_is_removed(self) -> None:
        record = {"message": {"content": "attach it <system-reminder>hidden memo</system-reminder> now"}}
        self.assertEqual(list(spoken_texts(record)), ["attach it now"])

    def test_tool_calls_and_results_are_not_spoken(self) -> None:
        record = {"message": {"content": [
            {"type": "text", "text": "Use JDI."},
            {"type": "tool_use", "name": "Bash", "input": {"command": "buried"}},
            {"type": "tool_result", "content": "output"},
        ]}}
        self.assertEqual(list(spoken_texts(record)), ["Use JDI."])

    def test_timestamps(self) -> None:
        self.assertEqual(timestamp("1970-01-01T00:00:10Z"), 10.0)
        self.assertIsNone(timestamp("yesterday"))
        self.assertIsNone(timestamp(None))


class ConversationTests(Workspace):
    def test_subagent_transcripts_belong_to_their_session(self) -> None:
        groups = group_by_session(self.paths.projects)
        self.assertEqual(set(groups), {"aaa", "bbb"})
        self.assertEqual(len(groups["aaa"]), 2)

    def test_the_main_transcript_is_found_rather_than_a_subagent(self) -> None:
        self.assertEqual(find_transcript(self.paths.projects, "aaa"), self.project / "aaa.jsonl")
        with self.assertRaises(ValueError):
            find_transcript(self.paths.projects, "nope")

    def test_a_conversation_reads_its_title_project_and_messages(self) -> None:
        conversation = read_conversation(group_by_session(self.paths.projects)["aaa"])
        self.assertEqual(conversation.name, "Kotlin debugger spike")
        self.assertEqual((conversation.project, conversation.branch), ("/tmp/demo", "stage"))
        self.assertEqual(len(conversation.messages), 4)
        self.assertEqual(sorted(conversation.days), ["2026-09-14", "2026-09-16"])
