from __future__ import annotations

from pathlib import Path


def write_atomic(path: Path, text: str) -> None:
    staged = path.with_name(path.name + ".tmp")
    staged.write_text(text, encoding="utf-8")
    staged.replace(path)
