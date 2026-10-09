#!/usr/bin/env python3
"""Browse and search Claude Code sessions and plans. Run: python3 claude_sessions.py"""
import errno, hashlib, http.server, json, re, sqlite3, subprocess, sys, webbrowser
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlparse, parse_qs

ROOT = Path.home() / ".claude" / "projects"
DB = Path.home() / ".claude" / "session-index-web.db"
PLANS = Path.home() / ".claude" / "plans"
SIDECAR = PLANS / ".plan-manager.json"
STATUSES = ("", "active", "completed")
SCANNED = set()
PORT = 8787
DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")
SPOKEN = re.compile(r'"type"\s*:\s*"(user|assistant)"')
NOISE = re.compile(
	r"<system-reminder>.*?</system-reminder>"
	r"|<command-name>.*?</command-name>"
	r"|<local-command-stdout>.*?</local-command-stdout>"
	r"|<command-message>.*?</command-message>"
	r"|<command-args>.*?</command-args>"
	r"|<local-command-caveat>.*?</local-command-caveat>"
	r"|<task-notification>.*?</task-notification>"
	r"|<persisted-output>.*?</persisted-output>", re.S)


def connect():
	db = sqlite3.connect(DB)
	db.executescript("""
		create table if not exists sessions(
			id text primary key, title text, project text, branch text,
			started real, modified real, size integer, turns integer,
			days text, indexed real);
		create virtual table if not exists msgs using fts5(
			text, sid unindexed, role unindexed, ts unindexed,
			tokenize='porter unicode61');
	""")
	return db


def transcripts():
	"""Every jsonl grouped by the session it belongs to, subagent files included."""
	groups = {}
	for path in ROOT.rglob("*.jsonl"):
		parts = path.relative_to(ROOT).parts
		if len(parts) >= 2:
			groups.setdefault(parts[1].removesuffix(".jsonl"), []).append(path)
	return groups


def stamp(value):
	try:
		return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
	except (AttributeError, TypeError, ValueError):
		return None


def texts(record):
	"""Spoken text only: no tool calls, tool results, thinking or injected context."""
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


def harvest(paths):
	"""One pass per transcript -> (metadata, [(role, ts, text)])."""
	meta, rows, days = {}, [], set()
	for path in sorted(paths):
		for line in path.open(encoding="utf-8", errors="replace"):
			if '"ai-title"' in line and "title" not in meta:
				try:
					meta["title"] = json.loads(line).get("aiTitle", "")
				except json.JSONDecodeError:
					pass
			if not SPOKEN.search(line):
				continue
			try:
				record = json.loads(line)
			except json.JSONDecodeError:
				continue
			role = record["type"]
			when = stamp(record.get("timestamp"))
			if when:
				days.add(datetime.fromtimestamp(when).strftime("%Y-%m-%d"))
				meta["started"] = min(meta.get("started", when), when)
			meta["project"] = meta.get("project") or record.get("cwd") or ""
			meta["branch"] = meta.get("branch") or record.get("gitBranch") or ""
			for text in texts(record):
				rows.append((text, role, when or 0))
				meta.setdefault("prompt", text[:200])
	meta["days"] = ",".join(sorted(days))
	return meta, rows


def reindex(force=False):
	"""Index transcripts whose mtime moved. Returns how many sessions were rebuilt."""
	db = connect()
	known = dict(db.execute("select id, indexed from sessions"))
	built = 0
	for sid, paths in transcripts().items():
		newest = max(p.stat().st_mtime for p in paths)
		if not force and known.get(sid, 0) >= newest:
			continue
		meta, rows = harvest(paths)
		db.execute("delete from msgs where sid = ?", (sid,))
		db.executemany("insert into msgs(text, sid, role, ts) values (?,?,?,?)",
		               [(t, sid, r, ts) for t, r, ts in rows])
		db.execute("""insert or replace into sessions
			values (?,?,?,?,?,?,?,?,?,?)""", (
			sid, meta.get("title") or meta.get("prompt") or "Untitled session",
			meta.get("project") or "", meta.get("branch") or "",
			meta.get("started") or newest, newest,
			sum(p.stat().st_size for p in paths), len(rows), meta["days"], newest))
		built += 1
	for gone in set(known) - set(transcripts()):
		db.execute("delete from msgs where sid = ?", (gone,))
		db.execute("delete from sessions where id = ?", (gone,))
	db.commit()
	db.close()
	return built


def fts_terms(text):
	"""User text -> safe FTS5 terms. Quoted runs stay phrases, trailing * is a prefix."""
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


SORTS = {"relevance": lambda r: r["rank"], "recent": lambda r: -r["modified"],
         "hits": lambda r: -r["hits"], "longest": lambda r: -r["turns"]}


def query(q="", role="", project="", branch="", since="", until="", sort="relevance", limit=300):
	db = connect()
	db.row_factory = sqlite3.Row
	since = since if DATE_RE.fullmatch(since or "") else ""
	until = until if DATE_RE.fullmatch(until or "") else ""
	rows = {r["id"]: dict(r, hits=0, rank=0, snip="") for r in db.execute("select * from sessions")}

	terms = fts_terms(q)
	if terms:
		where, extra = ["msgs match ?"], []
		if role in ("user", "assistant"):
			where.append("role = ?"); extra.append(role)
		clause = " and ".join(where)

		# Each term is matched separately so a session qualifies when every term
		# appears somewhere in it, not all inside one message.
		per_term = [dict(db.execute(
			f"select sid, count(*) from msgs where {clause} group by sid", [term] + extra))
			for term in terms]
		found = set.intersection(*(set(f) for f in per_term))
		pick = terms[min(range(len(terms)), key=lambda i: len(per_term[i]))]
		best = {}
		for sid, snip in db.execute(
				f"select sid, snippet(msgs, 0, char(1), char(2), '...', 14) from msgs"
				f" where {clause} order by rank", [pick] + extra):
			best.setdefault(sid, snip)
		counts = {sid: sum(f[sid] for f in per_term) for sid in found}
		for rank, (sid, count) in enumerate(sorted(counts.items(), key=lambda kv: -kv[1])):
			if sid in rows:
				rows[sid].update(hits=count, rank=rank, snip=best.get(sid, ""))
		keep = [r for sid, r in rows.items() if sid in found]
	else:
		keep = list(rows.values())
		sort = "recent" if sort == "relevance" else sort

	# "active on" is a property of the session, not of the matching message
	span = list(day_range(since, until))[:400] if (since or until) else []
	if span:
		keep = [r for r in keep if any(day in r["days"] for day in span)]
	if project:
		keep = [r for r in keep if repo_of(r["project"]) == project]
	else:
		hidden = archived_paths()
		keep = [r for r in keep if repo_of(r["project"]) not in hidden]
	if branch:
		keep = [r for r in keep if r["branch"] == branch]
	keep.sort(key=SORTS.get(sort, SORTS["recent"]))
	db.close()
	return [{k: r[k] for k in
	         ("id", "title", "project", "branch", "modified", "size", "turns", "hits", "snip")}
	        for r in keep[:limit]]


def day_range(since, until):
	day = datetime.fromisoformat(since or until)
	end = datetime.fromisoformat(until or since)
	while day <= end:
		yield day.strftime("%Y-%m-%d")
		day += timedelta(days=1)


def repo_of(path):
	return path.split("/.claude/worktrees/")[0]


def facets():
	db = connect()
	pick = lambda col: [r[0] for r in db.execute(
		f"select {col} from sessions where {col} != '' group by {col} order by count(*) desc")]
	repos = Counter(repo_of(r[0]) for r in db.execute("select project from sessions where project != ''"))
	hidden = archived_paths()
	ranked = [repo for repo, _ in repos.most_common()]
	out = {"projects": ranked, "counts": dict(repos),
	       "archived": [repo for repo in ranked if repo in hidden],
	       "branches": pick("branch"),
	       "total": db.execute("select count(*) from sessions").fetchone()[0] - sum(repos[p] for p in hidden),
	       "turns": db.execute("select sum(turns) from sessions").fetchone()[0] or 0}
	db.close()
	return out


def archived_paths():
	return {record["path"] for record in read_meta().get("projects", {}).values()
	        if record.get("archived") and record.get("path")}


def set_archived(path, archived):
	if not isinstance(archived, bool):
		raise ValueError("archived must be true or false")
	if path not in facets()["projects"]:
		raise ValueError(f"Unknown project {path!r}")
	meta = read_meta()
	meta["projects"][project_key(meta, path)]["archived"] = archived
	write_meta(meta)


def read_meta():
	try:
		return json.loads(SIDECAR.read_text(encoding="utf-8"))
	except FileNotFoundError:
		return {}


def write_atomic(path, text):
	staged = path.with_name(path.name + ".tmp")
	staged.write_text(text, encoding="utf-8")
	staged.replace(path)


def write_meta(meta):
	PLANS.mkdir(parents=True, exist_ok=True)
	write_atomic(SIDECAR, json.dumps(meta, indent=2, sort_keys=True))


def now_iso():
	return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def project_key(meta, path):
	projects = meta.setdefault("projects", {})
	for key, record in projects.items():
		if record.get("path") == path:
			return key
	key = hashlib.sha256(path.encode()).hexdigest()[:16]
	projects[key] = {"name": Path(path).name, "path": path, "pinned": False}
	return key


def load_plans():
	meta = read_meta()
	entries = meta.get("plans", {})
	projects = meta.get("projects", {})
	overrides = meta.get("planProjectOverrides", {})
	scanned = meta.get("projectScan", {}).get("assignments", {})
	plans = []
	for path in PLANS.glob("*.md"):
		body = path.read_text(encoding="utf-8", errors="replace")
		info = path.stat()
		entry = entries.get(path.stem, {})
		key = overrides.get(path.stem) or scanned.get(path.stem)
		plans.append({
			"id": path.stem,
			"title": next((line[2:] for line in body.splitlines() if line.startswith("# ")), path.stem),
			"body": body,
			"project": repo_of(projects.get(key, {}).get("path", "")),
			"status": entry.get("status", ""),
			"pinned": entry.get("pinned", False),
			"tags": entry.get("tags", []),
			"progress": entry.get("readingProgress", 0),
			"modified": info.st_mtime,
			"size": info.st_size})
	plans.sort(key=lambda plan: (not plan["pinned"], -plan["modified"]))
	return plans


def writers_of(ids):
	earliest = {}
	for sid, paths in transcripts().items():
		for path in paths:
			blob = path.read_bytes()
			if b".claude/plans/" not in blob:
				continue
			for line in blob.decode("utf-8", "replace").splitlines():
				if '"name":"Write"' not in line:
					continue
				for pid in ids:
					if f".claude/plans/{pid}.md" not in line:
						continue
					try:
						when = stamp(json.loads(line).get("timestamp"))
					except json.JSONDecodeError:
						continue
					if when and when < earliest.get(pid, (float("inf"), ""))[0]:
						earliest[pid] = (when, sid)
	db = connect()
	found = {}
	for pid, (_, sid) in earliest.items():
		row = db.execute("select project from sessions where id = ?", (sid,)).fetchone()
		if row and row[0]:
			found[pid] = row[0]
	db.close()
	return found


def resolve_projects():
	missing = [plan["id"] for plan in load_plans() if not plan["project"] and plan["id"] not in SCANNED]
	if not missing:
		return
	SCANNED.update(missing)
	reindex()
	found = writers_of(missing)
	if not found:
		return
	meta = read_meta()
	scan = meta.setdefault("projectScan", {})
	assignments = scan.setdefault("assignments", {})
	for pid, path in found.items():
		assignments[pid] = project_key(meta, path)
	scan["scannedAt"] = now_iso()
	write_meta(meta)


def plan_file(pid):
	if not isinstance(pid, str):
		raise ValueError("A plan id is required")
	path = PLANS / f"{pid}.md"
	if path.parent != PLANS or not path.is_file():
		raise ValueError(f"No plan named {pid!r}")
	return path


def plan_change(change):
	unknown = set(change) - {"body", "project", "status", "pinned", "tags", "progress"}
	if unknown:
		raise ValueError(f"Unknown plan fields: {', '.join(sorted(unknown))}")
	if "body" in change and not isinstance(change["body"], str):
		raise ValueError("body must be text")
	if "project" in change and change["project"] not in facets()["projects"]:
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


def edit_plan(pid, change):
	path = plan_file(pid)
	entry = plan_change(change)
	if "body" in change:
		write_atomic(path, change["body"])
	if not entry and "project" not in change:
		return
	meta = read_meta()
	if "project" in change:
		meta.setdefault("planProjectOverrides", {})[pid] = project_key(meta, change["project"])
	if entry:
		meta.setdefault("plans", {}).setdefault(pid, {}).update(entry, lastReadAt=now_iso())
	write_meta(meta)


def delete_plan(pid):
	plan_file(pid).unlink()
	meta = read_meta()
	if meta.get("plans", {}).pop(pid, None) is not None:
		write_meta(meta)


def transcript_file(sid):
	paths = transcripts().get(sid)
	if not paths:
		raise ValueError(f"No transcript for session {sid!r}")
	return min(paths, key=lambda path: len(path.parts))


def show(path, select=False):
	if sys.platform == "darwin":
		command = ["open", "-R", str(path)] if select else ["open", str(path)]
	else:
		command = ["xdg-open", str(path.parent if select else path)]
	subprocess.run(command, check=True, capture_output=True)


def allowed(host, origin, writing):
	local = host in (f"localhost:{PORT}", f"127.0.0.1:{PORT}")
	return local and (not writing or origin == f"http://{host}")


def self_check():
	global ROOT, DB, PLANS, SIDECAR
	import tempfile
	with tempfile.TemporaryDirectory() as tmp:
		ROOT, DB = Path(tmp) / "projects", Path(tmp) / "index.db"
		PLANS = Path(tmp) / "plans"
		SIDECAR = PLANS / ".plan-manager.json"
		project = ROOT / "-tmp-demo"
		(project / "aaa" / "subagents").mkdir(parents=True)
		line = lambda **kw: json.dumps(kw, separators=(",", ":")) + "\n"
		wrote = lambda when: line(type="assistant", timestamp=when, message={"content": [
			{"type": "tool_use", "name": "Write", "input": {"file_path": "/home/u/.claude/plans/alpha.md"}}]})
		(project / "aaa.jsonl").write_text(
			line(type="ai-title", aiTitle="Kotlin debugger spike")
			+ line(type="user", timestamp="2026-09-14T10:00:00Z", cwd="/tmp/demo", gitBranch="stage",
			       message={"content": "how do I attach the kotlin debugger <system-reminder>hidden memo</system-reminder>"})
			+ line(type="assistant", timestamp="2026-09-14T10:01:00Z", cwd="/tmp/demo", gitBranch="stage",
			       message={"content": [{"type": "text", "text": "Use JDI to attach."},
			                            {"type": "tool_use", "name": "Bash", "input": {"command": "buried"}}]})
			+ line(type="user", timestamp="2026-09-14T10:02:00Z",
			       message={"content": [{"type": "tool_result", "content": "unspoken output"}]})
			+ wrote("2026-09-14T10:04:00Z"))
		(project / "aaa.jsonl").write_text((project / "aaa.jsonl").read_text()
			+ line(type="user", timestamp="2026-09-16T08:00:00Z", message={"content": "unrelated chatter"}))
		(project / "aaa" / "subagents" / "agent-1.jsonl").write_text(
			line(type="assistant", timestamp="2026-09-14T10:03:00Z", message={"content": [{"type": "text", "text": "subagent said pangolin"}]}))
		(project / "bbb.jsonl").write_text(
			line(type="user", timestamp="2026-09-15T09:00:00Z", cwd="/other", gitBranch="main",
			     message={"content": "unrelated kotlin work"})
			+ wrote("2026-09-15T09:30:00Z"))

		assert reindex() == 2, "both sessions indexed"
		assert reindex() == 0, "unchanged transcripts are skipped"
		ids = lambda **kw: {r["id"] for r in query(**kw)}

		assert ids(q="pangolin") == {"aaa"}, "subagent text credits the parent"
		assert ids(q="hidden memo") == set(), "system-reminder text is not indexed"
		assert ids(q="buried") == set(), "tool inputs are not indexed"
		assert ids(q="unspoken output") == set(), "tool results are not indexed"
		assert ids(q="kotlin") == {"aaa", "bbb"}, "plain word"
		assert ids(q="kotlin debugger") == {"aaa"}, "multiple words are ANDed"
		assert ids(q="attach JDI") == {"aaa"}, "words may sit in different messages"
		assert ids(q="attach pangolin") == {"aaa"}, "and in different transcripts of one session"
		assert ids(q="attach nonexistentword") == set(), "every term must appear"
		assert ids(q='"attach the kotlin"') == {"aaa"}, "quoted run is a phrase"
		assert ids(q='"kotlin attach"') == set(), "phrase respects word order"
		assert ids(q="debug*") == {"aaa"}, "trailing star is a prefix"
		assert ids(q="kotlin", role="user") == {"aaa", "bbb"}, "role filter keeps my prompts"
		assert ids(q="JDI", role="user") == set(), "role filter excludes Claude's replies"
		assert ids(q="kotlin", since="2026-09-15", until="2026-09-15") == {"bbb"}, "date filter"
		assert ids(q="debugger", since="2026-09-16", until="2026-09-16") == {"aaa"}, \
			"date filter is 'session was active then', not 'the word was said then'"
		assert ids(since="2026-09-16", until="2026-09-16") == {"aaa"}, "browse agrees with search"
		assert ids(since="2026-09-14", until="2026-09-14") == {"aaa"}, "date filter without a query"
		assert ids(since="2026-09-14", until="2026-09-15") == {"aaa", "bbb"}, "date range"
		assert ids(project="/other") == {"bbb"} and ids(branch="stage") == {"aaa"}, "project/branch"
		assert ids(q="kotlin", branch="main") == {"bbb"}, "search plus filter"
		assert ids(q='"unbalanced AND NOT (') == set(), "fts operators are treated as text"
		assert ids(since="nonsense") == {"aaa", "bbb"}, "a bad date is ignored, not fatal"

		hit = [r for r in query(q="debugger") if r["id"] == "aaa"][0]
		assert hit["title"] == "Kotlin debugger spike" and hit["branch"] == "stage"
		assert "\x01debugger\x02" in hit["snip"], f"snippet marks the term: {hit['snip']}"
		assert hit["turns"] == 4, f"4 spoken messages, got {hit['turns']}"
		assert facets()["projects"] == ["/tmp/demo", "/other"] or set(facets()["projects"]) == {"/tmp/demo", "/other"}

		(project / "ccc.jsonl").write_text(
			line(type="user", timestamp="2026-09-17T09:00:00Z", cwd="/tmp/demo/.claude/worktrees/wt",
			     gitBranch="wt", message={"content": "worktree chat"}))
		assert reindex() == 1
		assert sorted(facets()["projects"]) == ["/other", "/tmp/demo"], "worktrees fold into their repo"
		assert ids(project="/tmp/demo") == {"aaa", "ccc"}, "a repo filter includes its worktrees"
		assert transcript_file("aaa") == project / "aaa.jsonl", "the main transcript, not a subagent's"

		def refused(call, *args):
			try:
				call(*args)
			except ValueError:
				return True
			return False

		assert refused(transcript_file, "nope")
		PLANS.mkdir()
		(PLANS / "alpha.md").write_text("# Alpha plan\n\nkotlin body\n")
		(PLANS / "beta.md").write_text("no heading here\n")
		resolve_projects()
		plans = lambda: {plan["id"]: plan for plan in load_plans()}
		assert plans()["alpha"]["project"] == "/tmp/demo", "the earliest session to write a plan owns it"
		assert plans()["alpha"]["title"] == "Alpha plan"
		assert plans()["beta"]["project"] == "" and plans()["beta"]["title"] == "beta"
		edit_plan("beta", {"pinned": True, "tags": [" spike ", ""], "status": "active"})
		assert load_plans()[0]["id"] == "beta", "pinned plans come first"
		assert plans()["beta"]["tags"] == ["spike"] and plans()["beta"]["status"] == "active"
		edit_plan("alpha", {"project": "/other", "progress": 0.5})
		assert plans()["alpha"]["project"] == "/other", "a chosen project beats the scan"
		assert plans()["alpha"]["progress"] == 0.5
		edit_plan("alpha", {"body": "# Renamed\n"})
		assert plans()["alpha"]["title"] == "Renamed"
		for pid, change in (("../alpha", {}), (None, {}), ("alpha", {"status": "done"}),
		                    ("alpha", {"progress": 2}), ("alpha", {"progress": True}),
		                    ("alpha", {"project": "/nowhere"}), ("alpha", {"pinned": "yes"}),
		                    ("alpha", {"tags": "spike"}), ("alpha", {"colour": "red"})):
			assert refused(edit_plan, pid, change), f"refused {pid!r} {change}"
		delete_plan("beta")
		assert set(plans()) == {"alpha"} and "beta" not in read_meta()["plans"]
		assert refused(delete_plan, "beta")

		assert allowed("localhost:8787", None, False) and not allowed("evil.test:8787", None, False)
		assert allowed("127.0.0.1:8787", "http://127.0.0.1:8787", True)
		assert not allowed("localhost:8787", "http://evil.test", True), "cross-site writes are refused"
		assert not allowed("localhost:8787", None, True)

		everyone = facets()["total"]
		set_archived("/other", True)
		assert facets()["archived"] == ["/other"] and facets()["total"] == everyone - 1
		assert ids() == {"aaa", "ccc"}, "an archived project leaves the full list"
		assert ids(q="kotlin") == {"aaa"}, "and leaves search across all projects"
		assert ids(project="/other") == {"bbb"}, "but opening it still shows its sessions"
		set_archived("/other", False)
		assert facets()["archived"] == [] and ids() == {"aaa", "bbb", "ccc"}, "unarchiving brings it back"
		assert refused(set_archived, "/nowhere", True) and refused(set_archived, "/other", "yes")

		(project / "bbb.jsonl").unlink()
		assert reindex() == 0 and ids() == {"aaa", "ccc"}, "deleted transcripts leave the index"
	print("self-check ok")


PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Claude Sessions</title>
<style>
:root{
--content:#ffffff;--label:#1d1d1f;--secondary:#5f5f64;--tertiary:#737378;--separator:#e3e3e7;
--fill:rgba(0,0,0,.05);--fill-strong:rgba(0,0,0,.09);--accent:#007aff;--on-accent:#ffffff;
--mark:rgba(0,122,255,.2);--code:#c41e4a;--error:#d70015;
--glass:rgba(236,236,241,.72);--rim:rgba(255,255,255,.85);--glass-line:rgba(0,0,0,.07);
--float:0 10px 30px rgba(0,0,0,.1);--lift:0 2px 10px rgba(0,0,0,.08);--pill:#ffffff;
--sans:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI Variable Text","Cantarell","Ubuntu","Noto Sans",sans-serif;
--mono:ui-monospace,"SF Mono",Menlo,"DejaVu Sans Mono",monospace;--bar:56px}
@media(prefers-color-scheme:dark){:root{
--content:#141415;--label:#f5f5f7;--secondary:#a1a1a6;--tertiary:#8d8d92;--separator:#2c2c2f;
--fill:rgba(255,255,255,.06);--fill-strong:rgba(255,255,255,.11);--accent:#0a84ff;
--mark:rgba(10,132,255,.34);--code:#ff6482;--error:#ff6961;
--glass:rgba(48,48,52,.62);--rim:rgba(255,255,255,.13);--glass-line:rgba(0,0,0,.5);
--float:0 12px 34px rgba(0,0,0,.5);--lift:0 2px 12px rgba(0,0,0,.35);--pill:rgba(255,255,255,.17)}}
*{box-sizing:border-box}
[hidden]{display:none!important}
html,body{height:100%}
body{margin:0;background:var(--content);color:var(--label);font:13px/1.4 var(--sans);-webkit-font-smoothing:antialiased;overflow:hidden}
button,input,select,textarea{font:inherit;color:inherit}
button{cursor:default}
:focus-visible{outline:3px solid color-mix(in srgb,var(--accent) 55%,transparent);outline-offset:1px}
.ico{width:16px;height:16px;flex:none}
.ico *{fill:none;stroke:currentColor;stroke-width:1.5;stroke-linecap:round;stroke-linejoin:round}
.glass{background:var(--glass);-webkit-backdrop-filter:blur(24px) saturate(1.8);backdrop-filter:blur(24px) saturate(1.8);
border:1px solid var(--glass-line);box-shadow:inset 0 1px 0 var(--rim),var(--float)}
.toolbar .glass{box-shadow:inset 0 1px 0 var(--rim),var(--lift)}

.window{display:grid;grid-template-columns:250px minmax(0,1fr);height:100vh;height:100dvh}
body.no-side .window{grid-template-columns:minmax(0,1fr)}
body.no-side .sidebar{display:none}
.sidebar{margin:8px 0 8px 8px;border-radius:18px;display:flex;flex-direction:column;min-height:0;overflow:hidden;z-index:4}
#projects{flex:1;padding:10px 8px}
.proj{display:flex;align-items:center;gap:8px;width:100%;height:28px;padding:0 10px;border:0;background:none;border-radius:8px;text-align:left}
.proj .n{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.c{color:var(--tertiary);font-size:11px;font-weight:400;font-variant-numeric:tabular-nums}
.proj:hover,.fold:hover{background:var(--fill)}
.proj[aria-current=true]{background:var(--fill-strong);font-weight:500}
.proj.archived .n{color:var(--secondary)}
.fold{display:flex;align-items:center;gap:6px;width:100%;height:28px;margin-top:12px;padding:0 10px;border:0;background:none;border-radius:8px;color:var(--secondary);font-size:11px;font-weight:600}
.fold .ico{width:10px;height:10px}
.fold[aria-expanded=true] .ico{transform:rotate(90deg)}
.fold .c{margin-left:auto}
.sidebar .seg{margin:0 10px 10px;background:var(--fill)}

.seg{display:flex;padding:2px;gap:2px;border-radius:999px}
.seg button{flex:1;border:0;background:none;border-radius:999px;padding:4px 12px;white-space:nowrap;transition:background-color .15s ease,box-shadow .15s ease}
.seg button:hover{background:var(--fill)}
.seg button[aria-pressed=true]{background:var(--pill);box-shadow:0 1px 3px rgba(0,0,0,.16)}

.content{position:relative;min-width:0;min-height:0;display:flex;flex-direction:column}
.toolbar{position:absolute;inset:0 0 auto;z-index:3;display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:10px 14px 10px 12px}
.toolbar::before{content:"";position:absolute;inset:0 0 -16px;z-index:-1;pointer-events:none;
background:color-mix(in srgb,var(--content) 60%,transparent);-webkit-backdrop-filter:blur(10px);backdrop-filter:blur(10px);
-webkit-mask-image:linear-gradient(#000 55%,transparent);mask-image:linear-gradient(#000 55%,transparent)}
.titles{min-width:0;margin:0 6px 0 4px;line-height:1.25}
h1{margin:0;font-size:13px;font-weight:600}
#subtitle{margin:0;font-size:11px;color:var(--secondary);white-space:nowrap}
#subtitle.err{color:var(--error)}
.icon{width:32px;height:32px;border-radius:999px;display:grid;place-items:center;padding:0}
.icon:disabled{color:var(--tertiary)}
.search{display:flex;align-items:center;gap:7px;height:32px;padding:0 12px;border-radius:999px;flex:1 1 240px;min-width:180px;max-width:420px;color:var(--secondary)}
.search:focus-within{outline:3px solid color-mix(in srgb,var(--accent) 55%,transparent)}
.search input{flex:1;min-width:0;border:0;background:none;outline:none;color:var(--label)}
.filters{display:flex;align-items:center;gap:8px;flex-wrap:wrap;justify-content:flex-end;margin-left:auto}
.toolbar .seg button{padding:5px 12px}
#branch{max-width:150px}
.pop{position:relative;display:inline-flex;align-items:center;height:32px;border-radius:999px}
.pop select{appearance:none;-webkit-appearance:none;border:0;background:none;height:100%;padding:0 28px 0 13px;border-radius:999px;max-width:190px;text-overflow:ellipsis;outline:none}
.pop:focus-within{outline:3px solid color-mix(in srgb,var(--accent) 55%,transparent)}
.pop .chev{position:absolute;right:11px;width:8px;height:12px;pointer-events:none;color:var(--secondary)}
.pop.small{height:26px;background:var(--fill)}
.pop.small select{padding:0 26px 0 10px;font-size:12px}

.scroll{overflow:auto;min-height:0}
#list{flex:1;padding:calc(var(--bar) + 4px) 10px 24px}
.row{display:grid;grid-template-columns:minmax(0,1fr) auto;column-gap:16px;align-items:baseline;padding:7px 12px 8px;border-radius:10px}
.row:hover:not([aria-selected=true]){background:var(--fill)}
.row:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}
.row[aria-selected=true]{background:var(--accent);color:var(--on-accent)}
.row[aria-selected=true] :is(.sub,.id,.snip){color:rgba(255,255,255,.85)}
.t{font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.id{font:11px var(--mono);color:var(--tertiary);text-align:right;white-space:nowrap}
.id.copied{color:var(--accent)}
.row[aria-selected=true] .id.copied{color:var(--on-accent);font-weight:600}
.sub,.snip{grid-column:1/-1;font-size:11px;color:var(--secondary);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sub span+span{margin-left:14px}
.snip{margin-top:2px}
.snip mark{background:var(--mark);color:var(--label);font-weight:500;border-radius:3px;padding:0 1px}
.row[aria-selected=true] .snip mark{background:rgba(255,255,255,.28);color:var(--on-accent)}
.empty{color:var(--secondary);padding:48px 16px;text-align:center;margin:0}

.split{flex:1;min-height:0;display:grid;grid-template-columns:minmax(260px,340px) minmax(0,1fr)}
#planList{padding:calc(var(--bar) + 4px) 10px 24px;border-right:1px solid var(--separator)}
.pin{width:7px;height:7px;border-radius:50%;background:var(--accent);align-self:center}
.row[aria-selected=true] .pin{background:var(--on-accent)}
.prog{grid-column:1/-1;height:3px;border-radius:2px;background:var(--fill-strong);margin-top:6px;overflow:hidden}
.prog i{display:block;height:100%;background:var(--accent);border-radius:2px}
.row[aria-selected=true] .prog i{background:var(--on-accent)}
#reader{min-width:0;min-height:0;display:flex;flex-direction:column;padding-top:var(--bar)}
#readerEmpty{margin:auto;color:var(--secondary)}
#readerBody{flex:1;min-height:0;display:flex;flex-direction:column}
.rhead{padding:10px 28px 0}
#rTitle{margin:0;font-size:17px;font-weight:600;letter-spacing:-.01em;line-height:1.3}
#rMeta{margin:3px 0 10px;font-size:11px;color:var(--tertiary)}
#rMeta span+span{margin-left:14px}
.tools{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
.btn{display:inline-flex;align-items:center;gap:5px;height:26px;padding:0 11px;border-radius:999px;border:0;background:var(--fill);font-size:12px;transition:background-color .15s ease,color .15s ease}
.btn:hover{background:var(--fill-strong)}
.btn[aria-pressed=true]{color:var(--accent)}
.btn[aria-pressed=true] .head{fill:currentColor}
.btn.danger:hover{color:var(--error)}
.back{display:none;margin-bottom:10px}
#tags{margin-top:8px;width:100%;max-width:420px;height:26px;padding:0 10px;border-radius:7px;border:1px solid var(--separator);background:var(--content);font-size:12px}
#tags:focus{outline:3px solid color-mix(in srgb,var(--accent) 55%,transparent);border-color:var(--accent)}
#doc,#editor{flex:1;min-height:0;margin-top:12px;border:0;border-top:1px solid var(--separator)}
#doc{overflow:auto;padding:14px 28px 40px}
#editor{resize:none;padding:14px 28px;background:none;font:12px/1.6 var(--mono);outline:none}
#editor:focus{border-top-color:var(--accent)}
#related{display:flex;flex-wrap:wrap;align-items:center;gap:6px;padding:10px 28px 14px;border-top:1px solid var(--separator);margin:0}
#related span{font-size:11px;color:var(--tertiary);margin-right:2px}
#related .btn{max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;display:block;line-height:26px;font-size:11px}

.md{font-size:13.5px;line-height:1.6}
.md>*{max-width:74ch}
.md h1{font-size:22px;font-weight:700;letter-spacing:-.02em;margin:10px 0 6px}
.md h2{font-size:17px;font-weight:600;letter-spacing:-.01em;margin:22px 0 5px}
.md h3{font-size:14px;font-weight:600;margin:16px 0 4px}
.md h4{font-size:12.5px;font-weight:600;margin:12px 0 4px}
.md p{margin:0 0 8px}
.md .li{position:relative;margin:0 0 3px;padding-left:calc(16px + var(--d)*18px)}
.md .li::before{content:"•";position:absolute;left:calc(3px + var(--d)*18px);color:var(--secondary)}
.md .li.n::before{content:none}
.md blockquote{margin:0 0 8px;padding-left:14px;border-left:2px solid var(--separator);color:var(--secondary)}
.md hr{border:0;border-top:1px solid var(--separator);margin:16px 0}
.md pre{margin:0 0 12px;padding:10px 14px;background:var(--fill);border-radius:8px;overflow-x:auto;font:12px/1.55 var(--mono)}
.md code{font:12px var(--mono);color:var(--code);background:var(--fill);padding:1px 4px;border-radius:4px}
.md pre code{color:var(--label);background:none;padding:0}
.md .table{overflow-x:auto;margin:0 0 12px}
.md table{border-collapse:collapse;font-size:12.5px}
.md th,.md td{border:1px solid var(--separator);padding:6px 9px;text-align:left;vertical-align:top}
.md th{font-weight:600;background:var(--fill)}
.md a{color:var(--accent)}

.menu{position:fixed;z-index:10;min-width:230px;padding:5px;border-radius:12px;display:flex;flex-direction:column;animation:appear .12s ease}
.menu button{display:flex;justify-content:space-between;gap:24px;border:0;background:none;text-align:left;padding:4px 10px;border-radius:6px}
.menu button:hover,.menu button:focus{background:var(--accent);color:var(--on-accent);outline:none}
.menu kbd{font:inherit;color:var(--tertiary)}
.menu button:hover kbd,.menu button:focus kbd{color:inherit}
.menu hr{border:0;border-top:1px solid var(--separator);margin:4px 8px}
@keyframes appear{from{opacity:0;transform:translateY(-3px)}}

body[data-mode=plans] .for-sessions,body[data-mode=sessions] .for-plans{display:none}

@media(max-width:760px){
.window,body.no-side .window{grid-template-columns:minmax(0,1fr)}
.sidebar,body.no-side .sidebar{display:flex;position:fixed;inset:8px auto 8px 8px;width:min(280px,82vw);margin:0}
body:not(.show-side) .sidebar{display:none}
.search{flex:1 1 100%;max-width:none;order:5}
.titles{flex:1}
.filters{order:6;margin-left:0;justify-content:flex-start}
.row:not(.plan){grid-template-columns:minmax(0,1fr)}
.row:not(.plan) .id{text-align:left}
.split{grid-template-columns:minmax(0,1fr)}
.split[data-open] #planList{display:none}
.split:not([data-open]) #reader{display:none}
.back{display:inline-flex}
.rhead,#doc,#editor,#related{padding-left:16px;padding-right:16px}
}
@media(prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
</style></head><body data-mode="sessions">
<div class="window">
<aside class="sidebar glass" id="sidebar" aria-label="Projects">
<nav id="projects" class="scroll"></nav>
<div class="seg" id="modes" role="group" aria-label="Show">
<button data-mode="sessions" aria-pressed="true">Sessions</button><button data-mode="plans" aria-pressed="false">Plans</button>
</div>
</aside>
<div class="content">
<header class="toolbar" id="toolbar">
<button class="icon glass" id="sideToggle" aria-label="Toggle sidebar" title="Toggle sidebar"><svg class="ico" viewBox="0 0 16 16" aria-hidden="true"><rect x="1.5" y="2.5" width="13" height="11" rx="2.5"/><path d="M6 2.5v11"/></svg></button>
<div class="titles"><h1>Claude Sessions</h1><p id="subtitle" aria-live="polite">Indexing transcripts...</p></div>
<label class="search glass"><svg class="ico" viewBox="0 0 16 16" aria-hidden="true"><circle cx="7" cy="7" r="4.75"/><path d="m10.5 10.5 3.5 3.5"/></svg><input id="q" type="search" placeholder="Search conversations" autocomplete="off" spellcheck="false" aria-label="Search"></label>
<div class="filters for-sessions">
<div class="seg glass" id="when" role="group" aria-label="Active">
<button data-back="" aria-pressed="true">Any day</button><button data-back="0" aria-pressed="false">Today</button><button data-back="1" aria-pressed="false">Yesterday</button><button data-back="6" aria-pressed="false">7 days</button>
</div>
<label class="pop glass"><select id="role" aria-label="Who said it"><option value="">Anyone said</option><option value="user">I said</option><option value="assistant">Claude said</option></select></label>
<label class="pop glass"><select id="branch" aria-label="Branch"><option value="">Any branch</option></select></label>
<label class="pop glass"><select id="sort" aria-label="Sort"><option value="relevance">Best match</option><option value="recent">Most recent</option><option value="hits">Most mentions</option><option value="longest">Longest</option></select></label>
<button class="icon glass" id="rebuild" aria-label="Rebuild index" title="Re-read every transcript from scratch"><svg class="ico" viewBox="0 0 16 16" aria-hidden="true"><path d="M13 8.5a5 5 0 1 1-1.7-4.2"/><path d="M12 1.75V4.6H9.15"/></svg></button>
</div>
</header>
<main id="list" class="scroll for-sessions" role="listbox" aria-label="Sessions"></main>
<section class="split for-plans" id="plans">
<div id="planList" class="scroll" role="listbox" aria-label="Plans"></div>
<article id="reader">
<p id="readerEmpty">Select a plan to read it.</p>
<div id="readerBody" hidden>
<div class="rhead">
<button class="btn back" id="back">All plans</button>
<h2 id="rTitle"></h2>
<p id="rMeta"></p>
<div class="tools">
<button class="btn" id="pin" aria-pressed="false"><svg class="ico" viewBox="0 0 16 16" aria-hidden="true"><path class="head" d="M5.5 2h5M6.5 2v4.5L4 9.5h8L9.5 6.5V2"/><path d="M8 9.5v5"/></svg><span>Pin</span></button>
<label class="pop small"><select id="status" aria-label="Status"><option value="">No status</option><option value="active">Active</option><option value="completed">Completed</option></select></label>
<label class="pop small"><select id="planProject" aria-label="Project"></select></label>
<button class="btn" id="openFile">Open in Editor</button>
<button class="btn" id="edit">Edit</button>
<button class="btn danger" id="del">Delete</button>
</div>
<input id="tags" placeholder="tags, comma separated" aria-label="Tags" autocomplete="off">
</div>
<div id="doc" class="md" tabindex="0"></div>
<textarea id="editor" hidden spellcheck="false" aria-label="Plan markdown"></textarea>
<p id="related" hidden></p>
</div>
</article>
</section>
</div>
</div>
<div class="menu glass" id="menu" role="menu" hidden></div>
<script>
const $=id=>document.getElementById(id);
const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const light=s=>esc(s).split('\u0001').map(p=>p.split('\u0002')).flatMap((p,i)=>i?['<mark>',p[0],'</mark>',p[1]||'']:[p[0]]).join('');
const base=p=>p.split('/').pop()||p;
const repoOf=p=>p.split('/.claude/worktrees/')[0];
const mac=/Mac/.test(navigator.platform);
const mod=e=>mac?e.metaKey:e.ctrlKey;
const stamp=t=>new Date(t*1000).toLocaleString([],{dateStyle:'medium',timeStyle:'short'});
const day=t=>new Date(t*1000).toLocaleDateString([],{dateStyle:'medium'});
const iso=d=>new Date(d-d.getTimezoneOffset()*6e4).toISOString().slice(0,10);
const sh=s=>/^[\w@%+=:,./-]+$/.test(s)?s:"'"+s.replace(/'/g,"'\\''")+"'";
const count=(n,word)=>`${n} ${word}${n===1?'':'s'}`;
const spans=items=>items.filter(Boolean).map(x=>`<span>${esc(x)}</span>`).join('');
const press=(group,on)=>group.querySelectorAll('button').forEach(b=>b.setAttribute('aria-pressed',b===on));
const STATUS={active:'Active',completed:'Completed'};
const CHEV='<svg class="ico chev" viewBox="0 0 8 12" aria-hidden="true"><path d="M1.5 4.5 4 2l2.5 2.5M1.5 7.5 4 10l2.5-2.5"/></svg>';
document.querySelectorAll('.pop').forEach(p=>p.insertAdjacentHTML('beforeend',CHEV));

const FOLD='<svg class="ico" viewBox="0 0 10 10" aria-hidden="true"><path d="M3.5 2 6.5 5l-3 3"/></svg>';
const planHash=id=>'#plans/'+encodeURIComponent(id);

let mode='sessions',project='',back='',facets=null,sessions=[],selected=null,plans=null,open=null,editing=false;
let runs=0,typing,noteTimer,progressTimer,returnFocus=null,menuItems=[],showArchived=false;

function subtitle(text,{error=false,flash=false}={}){
  clearTimeout(noteTimer);
  $('subtitle').textContent=text;$('subtitle').classList.toggle('err',error);
  if(flash)noteTimer=setTimeout(countLine,1400);
}
const report=e=>subtitle(e.message,{error:true});
function countLine(){
  const [n,total,unit]=mode==='plans'?[shownPlans().length,plans.length,'plans']:[sessions.length,facets.total,'sessions'];
  subtitle(n===total?`${total} ${unit}`:`${n} of ${total} ${unit}`);
}
async function api(path,data){
  const r=await fetch(path,data===undefined?{}:{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});
  const out=await r.json();
  if(!r.ok)throw new Error(out.error);
  return out;
}
const refresh=()=>mode==='plans'?renderPlans():run();

function select(list,id,focus){
  for(const r of list.querySelectorAll('.row')){
    const on=r.dataset.id===id;
    r.setAttribute('aria-selected',on);r.tabIndex=on?0:-1;
    if(on&&focus){r.focus();r.scrollIntoView({block:'nearest'})}
  }
}
function arrows(list,pick){
  list.addEventListener('keydown',e=>{
    const r=e.target.closest('.row');
    if(!r||(e.key!=='ArrowDown'&&e.key!=='ArrowUp'))return;
    e.preventDefault();
    const next=e.key==='ArrowDown'?r.nextElementSibling:r.previousElementSibling;
    if(next?.classList.contains('row'))pick(next.dataset.id,true);
  });
}

function renderProjects(){
  const hidden=new Set(facets.archived),shown=facets.projects.filter(p=>!hidden.has(p));
  const row=(path,name,n,extra='')=>`<button class="proj${extra}" data-path="${esc(path)}" title="${esc(path||name)}" aria-current="${path===project}"><span class="n">${esc(name)}</span><span class="c">${n}</span></button>`;
  $('projects').innerHTML=row('','All projects',shown.reduce((sum,p)=>sum+facets.counts[p],0))
    +shown.map(p=>row(p,base(p),facets.counts[p])).join('')
    +(hidden.size?`<button class="fold" id="fold" aria-expanded="${showArchived}">${FOLD}Archived<span class="c">${hidden.size}</span></button>`
      +(showArchived?facets.archived.map(p=>row(p,base(p),facets.counts[p],' archived')).join(''):''):'');
}
const projectMenu=path=>facets.archived.includes(path)
  ?[{label:'Unarchive Project',run:()=>archive(path,false)}]
  :[{label:'Archive Project',run:()=>archive(path,true)}];
async function archive(path,on){
  try{({plans,facets}=await api('/api/project/archive',{path,archived:on}))}catch(e){return report(e)}
  if(on&&project===path)project='';
  if(!facets.archived.length)showArchived=false;
  renderProjects();
  await refresh();
  subtitle(`${on?'Archived':'Unarchived'} ${base(path)}`,{flash:true});
}
function fillBranches(){
  const was=$('branch').value;
  $('branch').innerHTML='<option value="">Any branch</option>'+facets.branches.map(b=>`<option value="${esc(b)}">${esc(b)}</option>`).join('');
  if(facets.branches.includes(was))$('branch').value=was;
}

async function run(){
  const seq=++runs,p=new URLSearchParams();
  for(const [k,v] of [['q',$('q').value],['role',$('role').value],['branch',$('branch').value],['sort',$('sort').value],['project',project]])if(v)p.set(k,v);
  if(back!==''){
    const today=new Date();today.setHours(0,0,0,0);
    const from=new Date(today-back*864e5);
    p.set('since',iso(from));p.set('until',iso(back==='1'?from:today));
  }
  try{
    const d=await api('/api/query?'+p);
    if(seq!==runs)return;
    sessions=d.rows;facets.total=d.total;renderSessions();countLine();
  }catch(e){report(e)}
}
function renderSessions(){
  if(!sessions.some(s=>s.id===selected))selected=null;
  const stop=selected??sessions[0]?.id;
  $('list').innerHTML=sessions.length?sessions.map(s=>`<div class="row" role="option" data-id="${esc(s.id)}" aria-selected="${s.id===selected}" tabindex="${s.id===stop?0:-1}">
<div class="t">${esc(s.title)}</div><div class="id">${esc(s.id)}</div>
<div class="sub">${spans([repoOf(s.project)!==project&&base(repoOf(s.project)),stamp(s.modified),count(s.turns,'message'),s.branch,s.hits&&count(s.hits,'mention')])}</div>
${s.snip?`<div class="snip">${light(s.snip)}</div>`:''}</div>`).join('')
  :'<p class="empty">No sessions match. Try fewer words or a wider time range.</p>';
}
const pickSession=(id,focus)=>{selected=id;select($('list'),id,focus)};
async function copyText(id,text,note){
  try{await navigator.clipboard.writeText(text)}catch(e){return report(e)}
  subtitle(note,{flash:true});
  const cell=$('list').querySelector(`.row[data-id="${CSS.escape(id)}"] .id`);
  if(!cell)return;
  cell.textContent='Copied to clipboard';cell.classList.add('copied');
  setTimeout(()=>{cell.textContent=id;cell.classList.remove('copied')},1400);
}
const copyId=id=>copyText(id,id,'Copied session id');
const copyResume=id=>{const s=sessions.find(x=>x.id===id);copyText(id,`cd ${sh(s.project||'.')} && claude --resume ${id}`,'Copied resume command')};
const reveal=id=>api('/api/session/reveal',{id}).catch(report);
const sessionMenu=id=>[
  {label:'Copy Session ID',key:mac?'⌘C':'Ctrl+C',run:()=>copyId(id)},
  {label:'Copy Resume Command',run:()=>copyResume(id)},
  null,
  {label:mac?'Show Transcript in Finder':'Open Transcript Folder',run:()=>reveal(id)}];

function openMenu(x,y,items){
  const m=$('menu');
  menuItems=items;
  m.innerHTML=items.map((item,i)=>item?`<button role="menuitem" data-i="${i}">${esc(item.label)}${item.key?`<kbd>${esc(item.key)}</kbd>`:''}</button>`:'<hr>').join('');
  returnFocus=document.activeElement;m.hidden=false;
  m.style.left=Math.max(8,Math.min(x,innerWidth-m.offsetWidth-8))+'px';
  m.style.top=Math.max(8,Math.min(y,innerHeight-m.offsetHeight-8))+'px';
  m.querySelector('button').focus();
}
function closeMenu(){
  if($('menu').hidden)return;
  $('menu').hidden=true;returnFocus?.focus();
}
$('menu').addEventListener('click',e=>{
  const b=e.target.closest('button');if(!b)return;
  closeMenu();menuItems[b.dataset.i].run();
});
$('menu').addEventListener('keydown',e=>{
  const items=[...$('menu').querySelectorAll('button')],at=items.indexOf(document.activeElement);
  if(e.key==='ArrowDown'||e.key==='ArrowUp'){e.preventDefault();items[(at+(e.key==='ArrowDown'?1:items.length-1))%items.length].focus()}
  else if(e.key==='Escape'||e.key==='Tab'){e.preventDefault();closeMenu()}
});

$('list').addEventListener('click',e=>{const r=e.target.closest('.row');if(r)pickSession(r.dataset.id)});
$('list').addEventListener('dblclick',e=>{const r=e.target.closest('.row');if(r)copyId(r.dataset.id)});
$('list').addEventListener('contextmenu',e=>{
  const r=e.target.closest('.row');if(!r)return;
  e.preventDefault();pickSession(r.dataset.id);openMenu(e.clientX,e.clientY,sessionMenu(r.dataset.id));
});
$('list').addEventListener('keydown',e=>{
  const r=e.target.closest('.row');if(!r)return;
  if(e.key==='Enter')copyId(r.dataset.id);
  if(e.key==='ContextMenu'||(e.shiftKey&&e.key==='F10')){
    e.preventDefault();pickSession(r.dataset.id);
    const box=r.getBoundingClientRect();openMenu(box.left+24,box.bottom-6,sessionMenu(r.dataset.id));
  }
});
$('list').addEventListener('scroll',closeMenu);
arrows($('list'),pickSession);

function shownPlans(){
  const needle=$('q').value.trim().toLowerCase();
  return plans.filter(p=>(project?p.project===project:!facets.archived.includes(p.project))
    &&(!needle||[p.title,p.body,...p.tags].some(x=>x.toLowerCase().includes(needle))));
}
function renderPlans(){
  if(!plans)return;
  const shown=shownPlans(),had=$('planList').contains(document.activeElement)&&document.activeElement.dataset.id;
  const stop=shown.some(p=>p.id===open)?open:shown[0]?.id;
  $('planList').innerHTML=shown.length?shown.map(p=>{
    const read=Number(p.progress)||0;
    return `<div class="row plan" role="option" data-id="${esc(p.id)}" aria-selected="${p.id===open}" tabindex="${p.id===stop?0:-1}">
<div class="t">${esc(p.title)}</div>${p.pinned?'<span class="pin" title="Pinned"></span>':'<span></span>'}
<div class="sub">${spans([base(p.project)||'Unassigned',STATUS[p.status],p.tags.join(', '),day(p.modified)])}</div>
${read>0&&read<1?`<div class="prog"><i style="width:${(read*100).toFixed(1)}%"></i></div>`:''}</div>`}).join('')
  :`<p class="empty">${plans.length?'No plans match. Try fewer words or another project.':'No plans yet. Plans you make in Claude Code show up here.'}</p>`;
  if(had)$('planList').querySelector(`.row[data-id="${CSS.escape(had)}"]`)?.focus({preventScroll:true});
  countLine();
}
async function loadPlans(){
  if(!plans)$('planList').innerHTML='<p class="empty">Reading plans...</p>';
  try{plans=(await api('/api/plans')).plans}catch(e){return report(e)}
  renderPlans();
  const linked=!open&&plans.find(p=>location.hash===planHash(p.id));
  if(linked)openPlan(linked.id);
  else if(open&&!editing)showPlan(open);
}
const current=()=>plans.find(p=>p.id===open);
const dirty=()=>editing&&$('editor').value!==current()?.body.replace(/\r\n/g,'\n');
const keep=()=>!dirty()||confirm('Discard your changes to this plan?');
function setEditing(on){
  editing=on;$('edit').textContent=on?'Save':'Edit';
  $('doc').hidden=on;$('editor').hidden=!on;
}
function openPlan(id,focus){
  if(id!==open&&!keep())return;
  open=id;setEditing(false);
  select($('planList'),id,focus);
  $('plans').dataset.open='';
  history.replaceState(null,'',planHash(id));
  showPlan(id);
}
function closePlan(){
  open=null;setEditing(false);
  history.replaceState(null,'','#plans');
  $('readerEmpty').hidden=false;$('readerBody').hidden=true;
  delete $('plans').dataset.open;
}
function showPlan(id){
  const p=plans.find(x=>x.id===id);
  if(!p)return closePlan();
  $('readerEmpty').hidden=true;$('readerBody').hidden=false;
  $('rTitle').textContent=p.title;
  $('rMeta').innerHTML=spans([p.id,stamp(p.modified),Math.max(1,Math.round(p.size/1024))+' KB']);
  syncFields(p);
  $('doc').innerHTML=md(p.body);
  requestAnimationFrame(()=>{const d=$('doc'),h=d.scrollHeight-d.clientHeight;d.scrollTop=h>0?(Number(p.progress)||0)*h:0});
}
function syncFields(p){
  $('pin').setAttribute('aria-pressed',p.pinned);
  $('pin').lastChild.textContent=p.pinned?'Pinned':'Pin';
  $('status').value=p.status;
  const paths=!p.project||facets.projects.includes(p.project)?facets.projects:[p.project,...facets.projects];
  $('planProject').innerHTML='<option value="" disabled>Unassigned</option>'+paths.map(v=>`<option value="${esc(v)}">${esc(base(v))}</option>`).join('');
  $('planProject').value=p.project;
  if(document.activeElement!==$('tags'))$('tags').value=p.tags.join(', ');
  const related=plans.filter(o=>o.id!==p.id&&((p.project&&o.project===p.project)||o.tags.some(t=>p.tags.includes(t)))).slice(0,4);
  $('related').hidden=!related.length;
  $('related').innerHTML='<span>Related</span>'+related.map(o=>`<button class="btn" data-id="${esc(o.id)}" title="${esc(o.title)}">${esc(o.title)}</button>`).join('');
}
async function savePlan(change,id=open){
  try{plans=(await api('/api/plan',{id,...change})).plans}
  catch(e){report(e)}
  renderPlans();
  if(id===open&&current())syncFields(current());
}

$('planList').addEventListener('click',e=>{const r=e.target.closest('.row');if(r)openPlan(r.dataset.id)});
$('planList').addEventListener('keydown',e=>{
  if((e.key==='Delete'||e.key==='Backspace')&&e.target.closest('.row')){e.preventDefault();deletePlan()}
});
arrows($('planList'),openPlan);
$('pin').onclick=()=>savePlan({pinned:$('pin').getAttribute('aria-pressed')!=='true'});
$('status').onchange=()=>savePlan({status:$('status').value});
$('planProject').onchange=()=>savePlan({project:$('planProject').value});
$('tags').addEventListener('change',()=>savePlan({tags:$('tags').value.split(',')}));
$('openFile').onclick=()=>api('/api/plan/open',{id:open}).catch(report);
$('related').onclick=e=>{const b=e.target.closest('button');if(b)openPlan(b.dataset.id)};
$('back').onclick=()=>{if(keep()){closePlan();renderPlans()}};
$('edit').onclick=async()=>{
  if(!editing){$('editor').value=current().body;setEditing(true);$('editor').focus();return}
  try{plans=(await api('/api/plan',{id:open,body:$('editor').value})).plans}catch(e){return report(e)}
  setEditing(false);renderPlans();showPlan(open);
};
$('editor').addEventListener('keydown',e=>{if(mod(e)&&e.key==='s'){e.preventDefault();$('edit').click()}});
async function deletePlan(){
  if(!open||!confirm('Delete this plan?\n\nThe markdown file is removed from ~/.claude/plans. This cannot be undone.'))return;
  try{plans=(await api('/api/plan/delete',{id:open})).plans}catch(e){return report(e)}
  closePlan();renderPlans();
}
$('del').onclick=deletePlan;
$('doc').addEventListener('scroll',()=>{
  const d=$('doc'),h=d.scrollHeight-d.clientHeight,id=open;
  if(!id||h<=0)return;
  const at=Math.min(1,Math.max(0,d.scrollTop/h));
  clearTimeout(progressTimer);
  progressTimer=setTimeout(()=>{
    const p=plans.find(x=>x.id===id);
    if(p&&Math.abs((Number(p.progress)||0)-at)*h>1)savePlan({progress:at},id);
  },400);
});

function inline(s){
  let out='',i=0,m;
  const take=(open,close)=>{
    if(!s.startsWith(open,i))return null;
    const from=i+open.length;if(from>=s.length)return null;
    const end=s.indexOf(close,from);if(end<0)return null;
    i=end+close.length;return s.slice(from,end);
  };
  while(i<s.length){
    if((m=take('`','`'))!==null)out+=`<code>${esc(m)}</code>`;
    else if((m=take('**','**'))!==null)out+=`<strong>${esc(m)}</strong>`;
    else if(s[i]==='['&&(m=/^\[([^\]]*)\]\(([^)]*)\)/.exec(s.slice(i)))){
      out+=/^https?:\/\//.test(m[2])?`<a href="${esc(m[2])}" target="_blank" rel="noreferrer">${esc(m[1])}</a>`:esc(m[1]);
      i+=m[0].length;
    }
    else if(s[i]==='*'&&(m=take('*','*'))!==null)out+=`<em>${esc(m)}</em>`;
    else out+=esc(s[i++]);
  }
  return out;
}
function block(line){
  const h=/^(#{1,4}) (.*)$/.exec(line);
  if(h)return `<h${h[1].length}>${inline(h[2])}</h${h[1].length}>`;
  const t=line.replace(/^ +/,''),d=Math.floor((line.length-t.length)/2);
  if(t.startsWith('- ')||t.startsWith('* '))return `<div class="li" style="--d:${d}">${inline(t.slice(2))}</div>`;
  if(/^\d+\./.test(t))return `<div class="li n" style="--d:${d}">${inline(t)}</div>`;
  if(t.startsWith('> '))return `<blockquote>${inline(t.slice(2))}</blockquote>`;
  if(t.startsWith('---')||t.startsWith('***'))return '<hr>';
  return t?`<p>${inline(line)}</p>`:'';
}
function md(text){
  const lines=text.replace(/\r\n/g,'\n').split('\n'),out=[];
  const isRow=l=>{const t=l.trim();return t.startsWith('|')&&t.slice(1).includes('|')};
  const isRule=l=>{const t=l.trim();return t.startsWith('|')&&/^[|: -]+$/.test(t)};
  const cells=l=>{const c=l.trim().split('|').map(x=>x.trim());if(c[0]==='')c.shift();if(c.at(-1)==='')c.pop();return c};
  for(let i=0;i<lines.length;){
    const line=lines[i];
    if(line.startsWith('```')){
      const code=[];i++;
      while(i<lines.length&&!lines[i].startsWith('```'))code.push(lines[i++]);
      i++;out.push(`<pre><code>${esc(code.join('\n'))}</code></pre>`);
    }else if(isRow(line)&&isRule(lines[i+1]??'')){
      const head=cells(line),body=[];i+=2;
      while(i<lines.length&&isRow(lines[i]))body.push(cells(lines[i++]));
      const n=Math.max(head.length,...body.map(r=>r.length));
      const tr=(r,tag)=>'<tr>'+Array.from({length:n},(_,c)=>`<${tag}>${inline(r[c]??'')}</${tag}>`).join('')+'</tr>';
      out.push(`<div class="table"><table><thead>${tr(head,'th')}</thead><tbody>${body.map(r=>tr(r,'td')).join('')}</tbody></table></div>`);
    }else{out.push(block(line));i++}
  }
  return out.join('');
}

function setMode(next){
  mode=next;document.body.dataset.mode=next;
  press($('modes'),$('modes').querySelector(`[data-mode=${next}]`));
  $('q').placeholder=next==='plans'?'Search plans':'Search conversations';
  history.replaceState(null,'',next==='sessions'?location.pathname
    :open?planHash(open):location.hash.startsWith('#plans/')?location.hash:'#plans');
  next==='plans'?loadPlans():run();
}
$('modes').addEventListener('click',e=>{const b=e.target.closest('button');if(b&&b.dataset.mode!==mode)setMode(b.dataset.mode)});
$('projects').addEventListener('click',e=>{
  if(e.target.closest('#fold')){showArchived=!showArchived;renderProjects();$('fold').focus();return}
  const b=e.target.closest('.proj');if(!b)return;
  project=b.dataset.path;renderProjects();document.body.classList.remove('show-side');refresh();
});
$('projects').addEventListener('contextmenu',e=>{
  const b=e.target.closest('.proj');if(!b?.dataset.path)return;
  e.preventDefault();openMenu(e.clientX,e.clientY,projectMenu(b.dataset.path));
});
$('projects').addEventListener('keydown',e=>{
  const b=e.target.closest('.proj');
  if(!b?.dataset.path||(e.key!=='ContextMenu'&&!(e.shiftKey&&e.key==='F10')))return;
  e.preventDefault();
  const box=b.getBoundingClientRect();openMenu(box.left+20,box.bottom-4,projectMenu(b.dataset.path));
});
$('when').addEventListener('click',e=>{const b=e.target.closest('button');if(!b)return;back=b.dataset.back;press($('when'),b);run()});
['role','branch','sort'].forEach(id=>$(id).addEventListener('change',run));
$('q').addEventListener('input',()=>{clearTimeout(typing);typing=setTimeout(refresh,mode==='plans'?60:120)});
$('rebuild').onclick=async()=>{
  subtitle('Rebuilding index...');$('rebuild').disabled=true;
  try{facets=(await api('/api/rebuild',{})).facets;renderProjects();fillBranches();await run()}
  catch(e){report(e)}
  finally{$('rebuild').disabled=false}
};
const narrow=matchMedia('(max-width:760px)');
$('sideToggle').onclick=()=>document.body.classList.toggle(narrow.matches?'show-side':'no-side');
document.addEventListener('pointerdown',e=>{
  if(!e.target.closest('#menu'))closeMenu();
  if(narrow.matches&&!e.target.closest('#sidebar,#sideToggle'))document.body.classList.remove('show-side');
});
document.addEventListener('keydown',e=>{
  if(mod(e)&&e.key.toLowerCase()==='f'){e.preventDefault();$('q').focus();$('q').select()}
  else if(mod(e)&&e.key.toLowerCase()==='c'&&!e.shiftKey&&mode==='sessions'&&selected
    &&!getSelection().toString()&&!e.target.matches('input,textarea')){e.preventDefault();copyId(selected)}
});
addEventListener('blur',closeMenu);
addEventListener('beforeunload',e=>{if(dirty())e.preventDefault()});
new ResizeObserver(([entry])=>document.body.style.setProperty('--bar',entry.target.offsetHeight+'px')).observe($('toolbar'));

api('/api/facets').then(f=>{
  facets=f;renderProjects();fillBranches();
  setMode(location.hash.startsWith('#plans')?'plans':'sessions');
}).catch(report);
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
	def do_GET(self):
		if not allowed(self.headers.get("Host"), self.headers.get("Origin"), False):
			return self.fail(403, f"Open this page at http://localhost:{PORT}/")
		route = urlparse(self.path)
		if route.path == "/api/query":
			args = {k: v[0] for k, v in parse_qs(route.query).items()
			        if k in ("q", "role", "project", "branch", "since", "until", "sort")}
			reindex()
			self.reply({"rows": query(**args), "total": facets()["total"]})
		elif route.path == "/api/facets":
			self.reply(facets())
		elif route.path == "/api/plans":
			resolve_projects()
			self.reply({"plans": load_plans()})
		else:
			self.send(PAGE.encode(), "text/html; charset=utf-8")

	def do_POST(self):
		if not allowed(self.headers.get("Host"), self.headers.get("Origin"), True):
			return self.fail(403, "Requests from other sites are refused")
		try:
			body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
			if not isinstance(body, dict):
				raise ValueError("Expected a JSON object")
			if self.path == "/api/plan":
				edit_plan(body.get("id"), {k: v for k, v in body.items() if k != "id"})
			elif self.path == "/api/plan/delete":
				delete_plan(body.get("id"))
			elif self.path == "/api/plan/open":
				show(plan_file(body.get("id")))
			elif self.path == "/api/session/reveal":
				show(transcript_file(body.get("id")), select=True)
			elif self.path == "/api/project/archive":
				set_archived(body.get("path"), body.get("archived"))
			elif self.path == "/api/rebuild":
				reindex(force=True)
			else:
				return self.fail(404, f"Nothing at {self.path}")
		except ValueError as exc:
			return self.fail(400, str(exc))
		except (OSError, subprocess.CalledProcessError) as exc:
			return self.fail(500, str(exc))
		self.reply({"plans": load_plans(), "facets": facets()})

	def send(self, body, ctype, status=200):
		self.send_response(status)
		self.send_header("Content-Type", ctype)
		self.send_header("Content-Length", str(len(body)))
		self.end_headers()
		self.wfile.write(body)

	def reply(self, data):
		self.send(json.dumps(data).encode(), "application/json")

	def fail(self, status, message):
		self.send(json.dumps({"error": message}).encode(), "application/json", status)

	def log_message(self, *args):
		pass


if __name__ == "__main__":
	if "--check" in sys.argv:
		self_check()
		raise SystemExit(0)
	if not ROOT.is_dir():
		raise SystemExit(f"No Claude Code sessions found at {ROOT}")
	url = f"http://localhost:{PORT}/"
	try:
		server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
	except OSError as exc:
		if exc.errno != errno.EADDRINUSE:
			raise
		print(f"Already running, opening {url}")
		webbrowser.open(url)
		raise SystemExit(0)
	print("Indexing transcripts...")
	print(f"  {reindex('--reindex' in sys.argv)} session(s) updated, {facets()['turns']} messages indexed")
	print(f"Sessions at {url}  (ctrl-c to stop)")
	webbrowser.open(url)
	with server:
		server.serve_forever()
