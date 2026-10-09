from __future__ import annotations


def allowed(host: str | None, origin: str | None, writing: bool, port: int) -> bool:
    local = host in (f"localhost:{port}", f"127.0.0.1:{port}")
    return local and (not writing or origin == f"http://{host}")
