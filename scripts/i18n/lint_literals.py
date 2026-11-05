#!/usr/bin/env python3
"""Flag Chinese string literals that bypass the String Catalog.

usage: scripts/i18n/lint_literals.py [--list] [path ...]

A CJK literal is fine when it is:
  - an argument of a localizing API: String(localized:), SettingsCopy.t(),
    LocalizedStringKey/LocalizedStringResource, or a SwiftUI initializer that
    takes a LocalizedStringKey (Text, Button, Label, Section, Toggle, ...);
  - inside a log call (logger.*, print, NSLog, os_log);
  - marked `// i18n-ignore: <reason>` on its first line or the line above
    (model-facing prompts, speech lexicons, identifiers, test data...);
  - in a file whose first 40 lines contain `// i18n-ignore-file: <reason>`.
`Text(verbatim:)` and `String` values shown in the UI are what this catches.
Exits 1 when violations remain.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DIRS = ["OasesChat", "Extensions"]
SKIP_PARTS = {"Debug", "Generated", "BuiltinSkills"}

CJK = re.compile(r"[぀-ヿ一-鿿가-힯]")
LOCALIZING_CALLS = {
    "String", "LocalizedStringKey", "LocalizedStringResource", "t",
    "Text", "Button", "Label", "Section", "Toggle", "Picker", "TextField", "SecureField",
    "Menu", "Link", "NavigationLink", "ContentUnavailableView", "LabeledContent",
    "Stepper", "DatePicker", "ColorPicker", "Slider", "GroupBox", "DisclosureGroup",
    "ShareLink", "ProgressView", "Gauge",
    "navigationTitle", "alert", "confirmationDialog", "accessibilityLabel",
    "accessibilityHint", "accessibilityValue", "help", "badge", "tabItem",
    "searchable", "keyboardShortcut", "contextMenu", "swipeActions",
}
LOG_CALLS = {"print", "NSLog", "os_log", "debugPrint", "fatalError", "assert", "assertionFailure", "precondition", "preconditionFailure"}
LOGGER_METHODS = {"debug", "info", "notice", "warning", "error", "fault", "critical", "trace", "log"}


def literals(text: str):
    """Yield (start, end, body) for every string literal, including raw
    (#"..."#) and multi-line (\"\"\"...\"\"\") ones; comments are skipped."""
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if c == "#" or c == '"':
            hashes = 0
            j = i
            while j < n and text[j] == "#":
                hashes += 1
                j += 1
            if j >= n or text[j] != '"':
                i += 1
                continue
            multi = text.startswith('"""', j)
            quote = '"""' if multi else '"'
            close = quote + "#" * hashes
            k = j + len(quote)
            depth = 0
            while k < n:
                if hashes == 0 and text[k] == "\\":
                    if text.startswith("\\(", k):
                        depth += 1
                        k += 2
                        continue
                    k += 2
                    continue
                if depth and text[k] == "(":
                    depth += 1
                elif depth and text[k] == ")":
                    depth -= 1
                elif not depth and text.startswith(close, k):
                    break
                elif not multi and text[k] == "\n":
                    break
                k += 1
            yield i, k + len(close), text[j + len(quote):k]
            i = k + len(close)
            continue
        i += 1


def enclosing_call(text: str, pos: int) -> tuple[str, str]:
    """Name of the innermost call whose parentheses contain `pos`, and the
    receiver text right before it (for `logger.info(`)."""
    depth = 0
    i = pos - 1
    while i >= 0:
        c = text[i]
        if c == ")" or c == "]" or c == "}":
            depth += 1
        elif c == "(" or c == "[" or c == "{":
            if depth == 0:
                if c != "(":
                    return "", ""
                j = i - 1
                while j >= 0 and text[j] in " \t":
                    j -= 1
                end = j + 1
                while j >= 0 and (text[j].isalnum() or text[j] == "_"):
                    j -= 1
                name = text[j + 1:end]
                receiver = text[max(0, j - 40):j + 1]
                return name, receiver
            depth -= 1
        i -= 1
    return "", ""


def allowed(text: str, start: int, lines: list[str], line_no: int) -> bool:
    here = lines[line_no - 1]
    above = lines[line_no - 2] if line_no >= 2 else ""
    if "i18n-ignore" in here or "i18n-ignore" in above:
        return True
    name, receiver = enclosing_call(text, start)
    if name in LOCALIZING_CALLS:
        return True
    if name in LOG_CALLS:
        return True
    if name in LOGGER_METHODS and re.search(r"(logger|log|Logger|os_log)\s*\.?\s*$", receiver.rstrip(".")):
        return True
    return False


def lint_file(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="ignore")
    head = "\n".join(text.splitlines()[:40])
    if "i18n-ignore-file" in head:
        return []
    lines = text.splitlines()
    out = []
    for start, _end, body in literals(text):
        if not CJK.search(body):
            continue
        line_no = text.count("\n", 0, start) + 1
        if not allowed(text, start, lines, line_no):
            snippet = body.strip().replace("\n", " ")[:60]
            out.append(f"{path.relative_to(ROOT)}:{line_no}: {snippet}")
    return out


def main(argv: list[str]) -> int:
    show = "--list" in argv
    targets = [Path(a).resolve() for a in argv if not a.startswith("--")] or [ROOT / d for d in DEFAULT_DIRS]
    files = []
    for t in targets:
        files += [t] if t.is_file() else sorted(t.rglob("*.swift"))
    files = [f for f in files if not SKIP_PARTS & set(f.parts)]
    violations = [v for f in files for v in lint_file(f)]
    if show:
        print("\n".join(violations))
    by_dir: dict[str, int] = {}
    for v in violations:
        parts = v.split(":", 1)[0].split("/")
        key = "/".join(parts[:3]) if len(parts) > 3 else "/".join(parts)
        by_dir[key] = by_dir.get(key, 0) + 1
    for k, c in sorted(by_dir.items(), key=lambda x: -x[1]):
        print(f"{c:5d}  {k}")
    print(f"{len(violations)} unlocalized CJK literal(s) in {len(files)} files")
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
