# Data format

Both versions read Claude Code's own files and share one settings file. Neither ever changes a transcript.

## Transcripts

Claude Code writes one JSON Lines file per session:

```
~/.claude/projects/<project folder>/<session id>.jsonl
~/.claude/projects/<project folder>/<session id>/subagents/<agent>.jsonl
```

Subagent transcripts count as part of their parent session. From each line, only these fields are read:

| Field | Used for |
|---|---|
| `type` | `user` and `assistant` lines are searched; an `ai-title` line gives the session its title |
| `aiTitle` | The session title, from the `ai-title` line |
| `timestamp` | When the session was active |
| `cwd` | The session's project. Folders under `<repo>/.claude/worktrees/` count as `<repo>` |
| `gitBranch` | The session's branch |
| `message.content` | A string, or a list of blocks of which only `{"type": "text"}` blocks are searched |

Text inside injected tags such as `<system-reminder>` and `<command-name>` is not searched.

## Plans

Each plan is a Markdown file, `~/.claude/plans/<plan id>.md`. Its title is its first `# ` heading, or its id if it has none.

## Settings: `~/.claude/plans/.plan-manager.json`

```json
{
  "plans": {
    "<plan id>": {
      "status": "",
      "pinned": false,
      "tags": [],
      "readingProgress": 0,
      "lastReadAt": "2026-10-09T15:40:00Z"
    }
  },
  "projects": {
    "<project key>": { "name": "app", "path": "/Users/me/code/app", "pinned": false, "archived": false }
  },
  "planProjectOverrides": { "<plan id>": "<project key>" },
  "projectScan": {
    "assignments": { "<plan id>": "<project key>" },
    "scannedAt": "2026-10-09T15:40:00Z"
  }
}
```

| Key | Meaning |
|---|---|
| `plans.*.status` | `""`, `"active"` or `"completed"` |
| `plans.*.readingProgress` | How far down the plan has been read, from 0 to 1 |
| `projects` | Every project either version has referred to. New keys are the first 16 hex digits of the SHA-256 of the path; existing keys are reused by matching `path` |
| `projects.*.archived` | Hidden from the sidebar and from "All projects" |
| `planProjectOverrides` | A project chosen by hand, which wins over the scan |
| `projectScan.assignments` | The project of the earliest session whose `Write` tool created the plan |

Keys neither version knows about, such as `settings` from the older Plan Manager app, are kept as they are. Both versions re-read the file before every change and replace it atomically, so changes made in one show up in the other.

## Search indexes

Each version keeps its own SQLite index, built only from the transcripts and safe to delete at any time:

| File | Used by |
|---|---|
| `~/.claude/session-index.db` | The macOS app |
| `~/.claude/session-index-web.db` | The web version |

Both use the same schema: a `sessions` table with one row per session and an FTS5 `msgs` table, tokenized with `porter unicode61`, holding the searchable text.
