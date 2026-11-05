#!/usr/bin/env bash
# Fail when user-visible text names the OpenAI / ChatGPT / GPT brand.
#
# The App Store build for mainland China must not show these brands; the UI
# calls the OpenAI-protocol provider "AI 供应商" / "AI provider" instead (see
# OasesChat/Services/Providers/BrandNeutralCopy.swift). Internal identifiers
# (ProviderType.openAI, LLMModel.provider "OpenAI", model ids, hosts, wire
# fields, log messages, comments) are allowed to keep the name.
#
# What is scanned:
#   * Swift string literals (comments skipped) —
#       - every literal under OasesChat/{Features,DesignSystem,App} and
#         Extensions/ (the UI layer);
#       - in OasesChat/Services, literals at user-copy call sites only
#         (String(localized:), SettingsCopy.t, Text/Label/Button, displayName:,
#         label:, message:/detail: of errors, NSLocalizedDescriptionKey, …).
#   * Localizable.xcstrings keys and translations, Info.plist strings,
#     project.yml, CuratedSkills.json, and the built-in skills' text shown in
#     the Skills UI: SKILL.md `name` / `description` and the first 5 non-empty
#     body lines (the detail-page preview), parsed like SkillStore.parse, plus
#     manifest `name` / `disabledReason`. Skill text is checked strictly (no
#     URL/host exemption), matching BrandNeutralCopy.containsBrand.
#
# Allowed in literals (code identifiers): URLs and host names, lowercase
# id-like tokens ("gpt-image-2", "openai-responses"), CONSTANT_CASE keys,
# dictionary keys, `case "…":` labels, arguments of hasPrefix/contains/==,
# and `domain:`/`provider:`/`id:`/`forKey:`-style arguments; logger/print
# lines are skipped.
#
# Usage: scripts/check_forbidden_brands.sh [-v]   (-v also lists allowed hits)
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

exec python3 - "$repo_root" "$@" <<'PY'
import bisect
import json
import plistlib
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
verbose = "-v" in sys.argv[2:]

FORBIDDEN = re.compile(r"(?i)\bopen\s?ai|chat\s?gpt|\bgpt")

UI_DIRS = ["OasesChat/Features", "OasesChat/DesignSystem", "OasesChat/App", "Extensions"]
SERVICE_DIRS = ["OasesChat/Services"]
# Implements the neutral wording; its regexes necessarily spell the brand.
SKIP_FILES = {"OasesChat/Services/Providers/BrandNeutralCopy.swift"}

STRING_START = re.compile(r'(#*)("""|")')
URL_OR_HOST = re.compile(
    r"https?://[^\s\"'<>)]*"
    r"|\b[\w-]+(?:\.[\w-]+)*\.(?:com|ai|io|net|org|dev)\b(?:/[^\s\"'<>)]*)?"
)
ID_LIKE = re.compile(r"^(?:[a-z0-9][a-z0-9._/:+-]*|[A-Z0-9_]+)$")
# Source text right before a literal that marks it as an identifier.
IDENT_BEFORE = re.compile(
    r"(?:\b(?:case|domain:|category:|forHTTPHeaderField:|forKey:|provider:|id:|key:|kind:|"
    r"service:|identifier:|systemName:|named:)\s*"
    r"|\b(?:hasPrefix|hasSuffix|contains|localizedCaseInsensitiveContains|"
    r"isLegacyActiveProvider|appendingPathComponent)\(\s*"
    r"|[=!]=\s*)$"
)
LOG_LINE = re.compile(r"\b(?:logger|Logger|log)\.\w+\(|\bprint\(|\bNSLog\(|\bos_log\(|AppLogger\(")
# User-copy call sites in the service layer: anywhere earlier on the line …
SERVICE_CALL = re.compile(
    r"String\(localized:|SettingsCopy\.t\(|\bText\(|\bLabel\(|\bButton\(|\.navigationTitle\(|\.alert\("
)
# … or the argument label right before the literal.
SERVICE_ARG = re.compile(
    r"\b(?:displayName|label|descriptionText|title|subtitle|placeholder|message|detail|"
    r"providerName|NSLocalizedDescriptionKey|disabledReason):\s*$"
)

violations: list[str] = []
allowed: list[str] = []
scanned = {"files": 0, "literals": 0}


def rel(path: Path) -> str:
    return path.relative_to(root).as_posix()


def report(where: str, text: str) -> None:
    violations.append(f"{where}: {FORBIDDEN.search(text).group(0)!r} in {text.strip()[:140]!r}")


def swift_literals(src: str):
    """Yield (offset, text) for each string literal, interpolations recursed."""
    out = []

    def code(i: int, interpolation: bool) -> int:
        depth = 0
        n = len(src)
        while i < n:
            if src.startswith("//", i):
                j = src.find("\n", i)
                i = n if j < 0 else j
                continue
            if src.startswith("/*", i):
                nest, i = 1, i + 2
                while i < n and nest:
                    if src.startswith("/*", i):
                        nest, i = nest + 1, i + 2
                    elif src.startswith("*/", i):
                        nest, i = nest - 1, i + 2
                    else:
                        i += 1
                continue
            m = STRING_START.match(src, i)
            if m and (src[i] == '"' or m.group(1)):
                i = string(i, m.group(1), m.group(2))
                continue
            c = src[i]
            if interpolation:
                if c == "(":
                    depth += 1
                elif c == ")":
                    if depth == 0:
                        return i + 1
                    depth -= 1
            i += 1
        return i

    def string(i: int, hashes: str, quote: str) -> int:
        start = i
        i += len(hashes) + len(quote)
        close = quote + hashes
        escape = "\\" + hashes
        buf = []
        n = len(src)
        while i < n:
            if src.startswith(close, i):
                i += len(close)
                break
            if src.startswith(escape + "(", i):
                i = code(i + len(escape) + 1, True)
                buf.append("\\(…)")
                continue
            if src.startswith(escape, i):
                buf.append(src[i:i + len(escape) + 1])
                i += len(escape) + 1
                continue
            if src[i] == "\n" and quote == '"':
                break
            buf.append(src[i])
            i += 1
        out.append((start, "".join(buf)))
        return i

    code(0, False)
    return out


def check_swift(path: Path, service_layer: bool) -> None:
    src = path.read_text(encoding="utf-8")
    line_starts = [0] + [m.end() for m in re.finditer("\n", src)]
    scanned["files"] += 1
    for offset, text in swift_literals(src):
        scanned["literals"] += 1
        if not FORBIDDEN.search(text):
            continue
        line_no = bisect.bisect_right(line_starts, offset)
        line_start = line_starts[line_no - 1]
        line_end = src.find("\n", offset)
        before = src[line_start:offset]
        line = src[line_start:line_end if line_end >= 0 else len(src)]
        after = src[offset:].split("\n", 1)[0]
        where = f"{rel(path)}:{line_no}"

        def allow(reason: str) -> None:
            allowed.append(f"{where}: [{reason}] {text.strip()[:100]!r}")

        if LOG_LINE.search(line):
            allow("log")
            continue
        if service_layer and not (SERVICE_CALL.search(before) or SERVICE_ARG.search(before)):
            allow("not user copy")
            continue
        # Multi-line literals: judge each line on its own.
        bad_lines = []
        for k, piece in enumerate(text.split("\n")):
            stripped = URL_OR_HOST.sub("", piece)
            if FORBIDDEN.search(stripped) and not ID_LIKE.match(piece.strip()):
                bad_lines.append((line_no + k, piece))
        if not bad_lines:
            allow("url/id")
            continue
        if IDENT_BEFORE.search(before):
            allow("identifier")
            continue
        # Dictionary key: the literal is followed by a colon ("OpenAI": …).
        literal_end = re.match(r'#*"(?:[^"\\\n]|\\.)*"#*\s*:', after)
        if literal_end and '"""' not in after[:3]:
            allow("dictionary key")
            continue
        for piece_line, piece in bad_lines:
            report(f"{rel(path)}:{piece_line}", piece)


def walk(dirs, suffix):
    for d in dirs:
        base = root / d
        if base.exists():
            yield from sorted(p for p in base.rglob(f"*{suffix}") if p.is_file())


for path in walk(UI_DIRS, ".swift"):
    if rel(path) not in SKIP_FILES:
        check_swift(path, service_layer=False)
for path in walk(SERVICE_DIRS, ".swift"):
    if rel(path) not in SKIP_FILES:
        check_swift(path, service_layer=True)


def check_text(where: str, text: str, strict: bool = False) -> None:
    scanned["literals"] += 1
    if FORBIDDEN.search(text if strict else URL_OR_HOST.sub("", text)):
        report(where, text)


# String catalog: keys and every translated value.
catalog = root / "OasesChat/Localization/Localizable.xcstrings"
if catalog.exists():
    scanned["files"] += 1
    strings = json.loads(catalog.read_text(encoding="utf-8")).get("strings", {})

    def values(node):
        if isinstance(node, dict):
            unit = node.get("stringUnit")
            if isinstance(unit, dict) and isinstance(unit.get("value"), str):
                yield unit["value"]
            for key, child in node.items():
                if key != "stringUnit":
                    yield from values(child)
        elif isinstance(node, list):
            for child in node:
                yield from values(child)

    for key, entry in strings.items():
        check_text(f"{rel(catalog)} key", key)
        for value in values(entry.get("localizations", {})):
            check_text(f"{rel(catalog)} [{key[:40]}]", value)

# Info.plist strings (usage descriptions, display names, …).
for plist in sorted(set(walk(["OasesChat/Resources", "Extensions"], "Info.plist"))):
    if "AlpineFakefs" in plist.parts or "BuiltinSkills" in plist.parts:
        continue
    scanned["files"] += 1

    def plist_strings(node, trail=""):
        if isinstance(node, dict):
            for k, v in node.items():
                yield from plist_strings(v, f"{trail}/{k}")
        elif isinstance(node, list):
            for v in node:
                yield from plist_strings(v, trail)
        elif isinstance(node, str):
            yield trail, node

    for trail, value in plist_strings(plistlib.loads(plist.read_bytes())):
        check_text(f"{rel(plist)} {trail}", value)

# project.yml (generates Info.plist values); comments skipped.
project = root / "project.yml"
if project.exists():
    scanned["files"] += 1
    for no, line in enumerate(project.read_text(encoding="utf-8").splitlines(), 1):
        body = line.split("#", 1)[0] if not line.lstrip().startswith("#") else ""
        if body.strip():
            check_text(f"{rel(project)}:{no}", body)

# Skill store catalog.
curated = root / "OasesChat/Resources/CuratedSkills.json"
if curated.exists():
    scanned["files"] += 1

    def json_strings(node):
        if isinstance(node, dict):
            for v in node.values():
                yield from json_strings(v)
        elif isinstance(node, list):
            for v in node:
                yield from json_strings(v)
        elif isinstance(node, str):
            yield node

    for value in json_strings(json.loads(curated.read_text(encoding="utf-8"))):
        check_text(rel(curated), value)

# Built-in skills: what the Skills UI shows (mirrors SkillStore.parse).
def parse_skill_md(content: str):
    """Return (name, description, [(line_no, preview_line)]) like SkillStore.parse."""
    lines = content.split("\n")
    opening = content.strip().startswith("---")
    start = 1 if opening else 0
    end = next((i for i in range(start, len(lines)) if lines[i].strip() == "---"), None)
    if end is None:
        return "", "", preview(lines, 0)
    if not opening:
        keys = [l.partition(":")[0].strip().lower() for l in lines[:end] if l.strip() and not l[:1].isspace()]
        if not all(re.fullmatch(r"[\w-]+", k) for k in keys) or not {"name", "description", "version"} & set(keys):
            return "", "", preview(lines, 0)
    fields, i = {}, start
    while i < end:
        key, sep, value = lines[i].partition(":")
        if not sep:
            i += 1
            continue
        key, value = key.strip().lower(), value.strip()
        if value[:1] in ("|", ">") and all(c in "-+0123456789" for c in value[1:]) and i + 1 < end:
            block, j = [], i + 1
            while j < end and (lines[j] == "" or lines[j][:1].isspace()):
                block.append(lines[j].strip())
                j += 1
            value = (" " if value[0] == ">" else "\n").join(block).strip()
            i = j
        else:
            i += 1
        fields[key] = value
    return fields.get("name", ""), fields.get("description", ""), preview(lines, end + 1)


def preview(lines, first):
    shown = [(first + k + 1, line) for k, line in enumerate(lines[first:]) if line.strip()]
    return shown[:5]


skills_dir = root / "OasesChat/Resources/BuiltinSkills"
if skills_dir.exists():
    for skill_md in sorted(skills_dir.glob("*/SKILL.md")):
        scanned["files"] += 1
        name, description, shown = parse_skill_md(skill_md.read_text(encoding="utf-8"))
        check_text(f"{rel(skill_md)} name", name, strict=True)
        check_text(f"{rel(skill_md)} description", description, strict=True)
        for line_no, line in shown:
            check_text(f"{rel(skill_md)}:{line_no} (detail preview)", line, strict=True)
    manifest = skills_dir / "manifest.json"
    if manifest.exists():
        scanned["files"] += 1
        for skill in json.loads(manifest.read_text(encoding="utf-8")).get("skills", []):
            for field in ("name", "disabledReason"):
                if isinstance(skill.get(field), str):
                    check_text(f"{rel(manifest)} {skill.get('id')}.{field}", skill[field], strict=True)

if verbose and allowed:
    print(f"allowed (identifiers / non-user text): {len(allowed)}")
    for line in allowed:
        print(f"  {line}")
if violations:
    print(f"forbidden brand words in user-facing text: {len(violations)}")
    for line in violations:
        print(f"  {line}")
    sys.exit(1)
print(f"OK: no OpenAI/ChatGPT/GPT in user-facing text "
      f"({scanned['files']} files, {scanned['literals']} strings scanned, {len(allowed)} identifier hits allowed)")
PY
