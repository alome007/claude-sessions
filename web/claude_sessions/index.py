from __future__ import annotations

import sqlite3
from contextlib import closing
from pathlib import Path

from .transcripts import group_by_session, read_conversation

SCHEMA = """
    create table if not exists sessions(
        id text primary key, title text, project text, branch text,
        started real, modified real, size integer, turns integer,
        days text, indexed real);
    create virtual table if not exists msgs using fts5(
        text, sid unindexed, role unindexed, ts unindexed,
        tokenize='porter unicode61');
"""


class SessionIndex:
    def __init__(self, database: Path, transcripts: Path) -> None:
        self.database = database
        self.transcripts = transcripts

    def connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.database)
        db.executescript(SCHEMA)
        return db

    def refresh(self, force: bool = False) -> int:
        with closing(self.connect()) as db:
            known = dict(db.execute("select id, indexed from sessions"))
            groups = group_by_session(self.transcripts)
            built = 0
            for session_id, paths in groups.items():
                newest = max(path.stat().st_mtime for path in paths)
                if not force and known.get(session_id, 0) >= newest:
                    continue
                self._store(db, session_id, paths, newest)
                built += 1
            for gone in set(known) - set(groups):
                db.execute("delete from msgs where sid = ?", (gone,))
                db.execute("delete from sessions where id = ?", (gone,))
            db.commit()
        return built

    def _store(self, db: sqlite3.Connection, session_id: str, paths: list[Path], newest: float) -> None:
        conversation = read_conversation(paths)
        db.execute("delete from msgs where sid = ?", (session_id,))
        db.executemany(
            "insert into msgs(text, sid, role, ts) values (?,?,?,?)",
            [(message.text, session_id, message.role, message.at) for message in conversation.messages],
        )
        db.execute(
            "insert or replace into sessions values (?,?,?,?,?,?,?,?,?,?)",
            (
                session_id,
                conversation.name,
                conversation.project,
                conversation.branch,
                conversation.started or newest,
                newest,
                sum(path.stat().st_size for path in paths),
                len(conversation.messages),
                ",".join(sorted(conversation.days)),
                newest,
            ),
        )

    def sessions(self) -> list[dict]:
        with closing(self.connect()) as db:
            db.row_factory = sqlite3.Row
            return [dict(row) for row in db.execute("select * from sessions")]

    def match_counts(self, term: str, role: str) -> dict[str, int]:
        clause, extra = _match_clause(role)
        with closing(self.connect()) as db:
            return dict(db.execute(f"select sid, count(*) from msgs where {clause} group by sid", [term, *extra]))

    def best_snippets(self, term: str, role: str) -> dict[str, str]:
        clause, extra = _match_clause(role)
        snippets: dict[str, str] = {}
        with closing(self.connect()) as db:
            query = f"select sid, snippet(msgs, 0, char(1), char(2), '...', 14) from msgs where {clause} order by rank"
            for session_id, snippet in db.execute(query, [term, *extra]):
                snippets.setdefault(session_id, snippet)
        return snippets

    def projects(self) -> list[str]:
        with closing(self.connect()) as db:
            return [row[0] for row in db.execute("select project from sessions where project != ''")]

    def branches(self) -> list[str]:
        with closing(self.connect()) as db:
            query = "select branch from sessions where branch != '' group by branch order by count(*) desc"
            return [row[0] for row in db.execute(query)]

    def totals(self) -> tuple[int, int]:
        with closing(self.connect()) as db:
            sessions = db.execute("select count(*) from sessions").fetchone()[0]
            turns = db.execute("select sum(turns) from sessions").fetchone()[0] or 0
        return sessions, turns

    def project_of(self, session_id: str) -> str | None:
        with closing(self.connect()) as db:
            row = db.execute("select project from sessions where id = ?", (session_id,)).fetchone()
        return row[0] if row else None


def _match_clause(role: str) -> tuple[str, list[str]]:
    if role:
        return "msgs match ? and role = ?", [role]
    return "msgs match ?", []
