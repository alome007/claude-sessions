from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterator

SPOKEN = re.compile(r'"type"\s*:\s*"(user|assistant)"')
NOISE = re.compile(
    r"<system-reminder>.*?</system-reminder>"
    r"|<command-name>.*?</command-name>"
    r"|<local-command-stdout>.*?</local-command-stdout>"
    r"|<command-message>.*?</command-message>"
    r"|<command-args>.*?</command-args>"
    r"|<local-command-caveat>.*?</local-command-caveat>"
    r"|<task-notification>.*?</task-notification>"
    r"|<persisted-output>.*?</persisted-output>",
    re.S,
)


@dataclass
class Message:
    text: str
    role: str
    at: float


@dataclass
class Conversation:
    title: str | None = None
    first_text: str = ""
    project: str = ""
    branch: str = ""
    started: float | None = None
    days: set[str] = field(default_factory=set)
    messages: list[Message] = field(default_factory=list)

    @property
    def name(self) -> str:
        return self.title or self.first_text or "Untitled session"


def group_by_session(root: Path) -> dict[str, list[Path]]:
    groups: dict[str, list[Path]] = {}
    for path in root.rglob("*.jsonl"):
        parts = path.relative_to(root).parts
        if len(parts) >= 2:
            groups.setdefault(parts[1].removesuffix(".jsonl"), []).append(path)
    return groups


def find_transcript(root: Path, session_id: str) -> Path:
    paths = group_by_session(root).get(session_id)
    if not paths:
        raise ValueError(f"No transcript for session {session_id!r}")
    return min(paths, key=lambda path: len(path.parts))


def timestamp(value: object) -> float | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (AttributeError, TypeError, ValueError):
        return None


def spoken_texts(record: dict) -> Iterator[str]:
    content = record.get("message", {}).get("content")
    blocks = [content] if isinstance(content, str) else content or []
    for block in blocks:
        if isinstance(block, str):
            raw = block
        elif isinstance(block, dict) and block.get("type") == "text":
            raw = block.get("text", "")
        else:
            continue
        clean = " ".join(NOISE.sub(" ", raw).split())
        if clean:
            yield clean


def read_conversation(paths: list[Path]) -> Conversation:
    conversation = Conversation()
    for path in sorted(paths):
        with path.open(encoding="utf-8", errors="replace") as lines:
            for line in lines:
                if '"ai-title"' in line and conversation.title is None:
                    try:
                        conversation.title = json.loads(line).get("aiTitle", "")
                    except json.JSONDecodeError:
                        pass
                if not SPOKEN.search(line):
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                _add_record(conversation, record)
    return conversation


def _add_record(conversation: Conversation, record: dict) -> None:
    role = record["type"]
    at = timestamp(record.get("timestamp"))
    if at:
        conversation.days.add(datetime.fromtimestamp(at).strftime("%Y-%m-%d"))
        conversation.started = at if conversation.started is None else min(conversation.started, at)
    conversation.project = conversation.project or record.get("cwd") or ""
    conversation.branch = conversation.branch or record.get("gitBranch") or ""
    for text in spoken_texts(record):
        conversation.messages.append(Message(text, role, at or 0))
        if not conversation.first_text:
            conversation.first_text = text[:200]
