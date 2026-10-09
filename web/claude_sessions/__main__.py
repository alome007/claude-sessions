from __future__ import annotations

import argparse
import errno
import webbrowser
from http.server import HTTPServer
from pathlib import Path

from .app import App
from .config import PORT, Paths
from .server.handler import handler_for


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="claude-sessions", description="Search your Claude Code sessions and read your plans.")
    parser.add_argument("--reindex", action="store_true", help="rebuild the search index from scratch")
    args = parser.parse_args(argv)

    app = App(Paths.under(Path.home()))
    if not app.paths.projects.is_dir():
        raise SystemExit(f"No Claude Code sessions found at {app.paths.projects}")
    url = f"http://localhost:{PORT}/"
    try:
        server = HTTPServer(("127.0.0.1", PORT), handler_for(app))
    except OSError as exc:
        if exc.errno != errno.EADDRINUSE:
            raise
        print(f"Already running, opening {url}")
        webbrowser.open(url)
        raise SystemExit(0)
    print("Indexing transcripts...")
    print(f"  {app.index.refresh(args.reindex)} session(s) updated, {app.facets()['turns']} messages indexed")
    print(f"Sessions at {url}  (ctrl-c to stop)")
    webbrowser.open(url)
    with server:
        server.serve_forever()


if __name__ == "__main__":
    main()
