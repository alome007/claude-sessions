from __future__ import annotations

import re
from collections import Counter
from datetime import datetime, timedelta
from typing import Iterator

from .index import SessionIndex
from .projects import repo_of

DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
SPEAKERS = ("user", "assistant")
RESULT_FIELDS = ("id", "title", "project", "branch", "modified", "size", "turns", "hits", "snip")
SORTS = {
    "relevance": lambda row: row["rank"],
    "recent": lambda row: -row["modified"],
    "hits": lambda row: -row["hits"],
    "longest": lambda row: -row["turns"],
}


def fts_terms(text: str) -> list[str]:
    terms = []
    for phrase, word in re.findall(r'"([^"]*)"|(\S+)', text):
        token = (phrase or word).replace('"', "")
        if not token:
            continue
        if phrase:
            terms.append(f'"{token}"')
        elif token.endswith("*"):
            terms.append(f'"{token[:-1]}"*')
        else:
            terms.append(f'"{token}"')
    return terms


def day_range(since: str, until: str) -> Iterator[str]:
    day = datetime.fromisoformat(since or until)
    end = datetime.fromisoformat(until or since)
    while day <= end:
        yield day.strftime("%Y-%m-%d")
        day += timedelta(days=1)


def search(
    index: SessionIndex,
    hidden: set[str],
    q: str = "",
    role: str = "",
    project: str = "",
    branch: str = "",
    since: str = "",
    until: str = "",
    sort: str = "relevance",
    limit: int = 300,
) -> list[dict]:
    since = since if DATE.fullmatch(since or "") else ""
    until = until if DATE.fullmatch(until or "") else ""
    rows = {row["id"]: dict(row, hits=0, rank=0, snip="") for row in index.sessions()}
    terms = fts_terms(q)
    if terms:
        keep = _matching(index, rows, terms, role if role in SPEAKERS else "")
    else:
        keep = list(rows.values())
        sort = "recent" if sort == "relevance" else sort

    span = list(day_range(since, until))[:400] if (since or until) else []
    if span:
        keep = [row for row in keep if any(day in row["days"] for day in span)]
    if project:
        keep = [row for row in keep if repo_of(row["project"]) == project]
    else:
        keep = [row for row in keep if repo_of(row["project"]) not in hidden]
    if branch:
        keep = [row for row in keep if row["branch"] == branch]
    keep.sort(key=SORTS.get(sort, SORTS["recent"]))
    return [{field: row[field] for field in RESULT_FIELDS} for row in keep[:limit]]


def _matching(index: SessionIndex, rows: dict[str, dict], terms: list[str], speaker: str) -> list[dict]:
    per_term = [index.match_counts(term, speaker) for term in terms]
    found = set.intersection(*(set(counts) for counts in per_term))
    rarest = terms[min(range(len(terms)), key=lambda i: len(per_term[i]))]
    snippets = index.best_snippets(rarest, speaker)
    hits = {session_id: sum(counts[session_id] for counts in per_term) for session_id in found}
    for rank, (session_id, count) in enumerate(sorted(hits.items(), key=lambda item: -item[1])):
        if session_id in rows:
            rows[session_id].update(hits=count, rank=rank, snip=snippets.get(session_id, ""))
    return [row for session_id, row in rows.items() if session_id in found]


def facets(index: SessionIndex, hidden: set[str]) -> dict:
    repos = Counter(repo_of(path) for path in index.projects())
    ranked = [repo for repo, _ in repos.most_common()]
    sessions, turns = index.totals()
    return {
        "projects": ranked,
        "counts": dict(repos),
        "archived": [repo for repo in ranked if repo in hidden],
        "branches": index.branches(),
        "total": sessions - sum(repos[path] for path in hidden),
        "turns": turns,
    }
