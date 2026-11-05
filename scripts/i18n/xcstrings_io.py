"""Read/write .xcstrings exactly the way Xcode formats them, so edits made
by scripts produce minimal diffs."""
from __future__ import annotations

import json
from pathlib import Path


def _dump(value, indent: int) -> str:
    pad = " " * indent
    if isinstance(value, dict):
        if not value:
            return "{\n\n" + pad + "}"
        items = [
            " " * (indent + 2) + json.dumps(k, ensure_ascii=False) + " : " + _dump(v, indent + 2)
            for k, v in value.items()
        ]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(value, list):
        if not value:
            return "[\n\n" + pad + "]"
        items = [" " * (indent + 2) + _dump(v, indent + 2) for v in value]
        return "[\n" + ",\n".join(items) + "\n" + pad + "]"
    return json.dumps(value, ensure_ascii=False)


def load(path: str | Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def save(path: str | Path, catalog: dict) -> None:
    # Xcode writes no trailing newline.
    Path(path).write_text(_dump(catalog, 0), encoding="utf-8")
