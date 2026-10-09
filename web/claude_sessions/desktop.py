from __future__ import annotations

import subprocess
import sys
from pathlib import Path


def show(path: Path, select: bool = False) -> None:
    if sys.platform == "darwin":
        command = ["open", "-R", str(path)] if select else ["open", str(path)]
    else:
        command = ["xdg-open", str(path.parent if select else path)]
    subprocess.run(command, check=True, capture_output=True)
