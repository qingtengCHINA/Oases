#!/usr/bin/env python3
"""Check that every string in the app's String Catalogs is translated into
every language the in-app language picker offers.

usage: scripts/i18n/check_coverage.py [--verbose] [catalog.xcstrings ...]

With no arguments, checks every *.xcstrings under OasesChat/ and the app
extensions (skipping bundled skills). Exits 1 when any key is missing a
translation, has an empty or untranslated value, or its format specifiers
differ from the source.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# Keep in sync with `supportedLanguages` in
# OasesChat/Features/Settings/EngineeringAppearanceSettingsView.swift.
LANGUAGES = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "ru"]

ROOT = Path(__file__).resolve().parents[2]
SEARCH_DIRS = ["OasesChat", "Extensions"]

SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h|hh|z|t|j|L)?[@dDuUxXoOfeEgGcCsSpaAi]")
CJK = re.compile(r"[一-鿿]")
LATIN_WORDS = re.compile(r"[A-Za-z]{3,}")
_KEEP_FILE = Path(__file__).with_name("keep_as_is.txt")
KEEP_AS_IS = {
    line.strip()
    for line in (_KEEP_FILE.read_text(encoding="utf-8").splitlines() if _KEEP_FILE.exists() else [])
    if line.strip() and not line.startswith("#")
}


def keep_for(lang: str) -> set[str]:
    """Per-language exceptions: words spelled the same as in English
    (keep_as_is.<lang>.txt, e.g. German "Name", "Status", "Browser")."""
    path = Path(__file__).with_name(f"keep_as_is.{lang}.txt")
    if not path.exists():
        return set()
    return {l.strip() for l in path.read_text(encoding="utf-8").splitlines() if l.strip() and not l.startswith("#")}


def specifiers(text: str) -> list[str]:
    """Format specifiers with positional indices dropped, sorted: `%1$@`
    and `%@` are the same argument slot once reordering is allowed."""
    return sorted(re.sub(r"%\d+\$", "%", s) for s in SPECIFIER.findall(text.replace("%%", "")))


def units(localization: dict) -> list[tuple[str, dict]]:
    """Every leaf stringUnit of a localization, including plural/device
    variations and substitutions, with a path for error messages."""
    found = []

    def walk(node: dict, path: str) -> None:
        if "stringUnit" in node:
            found.append((path or "value", node["stringUnit"]))
        for kind, cases in (node.get("variations") or {}).items():
            for case, child in cases.items():
                walk(child, f"{path}{kind}.{case}/")
        for name, sub in (node.get("substitutions") or {}).items():
            walk(sub, f"{path}sub.{name}/")

    walk(localization, "")
    return found


def check_catalog(path: Path, verbose: bool) -> tuple[int, dict[str, int], list[str]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    source = data.get("sourceLanguage", "en")
    strings = data.get("strings", {})
    missing = {lang: 0 for lang in LANGUAGES}
    problems: list[str] = []
    total = 0

    for key, entry in sorted(strings.items()):
        if entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
            continue
        if not key.strip():
            continue
        total += 1
        localizations = entry.get("localizations") or {}
        source_units = units(localizations.get(source, {}))
        source_text = source_units[0][1].get("value", key) if source_units else key
        source_specs = specifiers(source_text)
        # The English wording to compare against: the en translation, or the
        # key itself when the key is English.
        en_units = units(localizations.get("en", {}))
        english_text = en_units[0][1].get("value") if en_units else (None if CJK.search(key) else key)

        for lang in LANGUAGES:
            loc = localizations.get(lang)
            if loc is None:
                # The source language may rely on the key itself, but only
                # when the key is actually written in that language.
                if lang == source and (source != "zh-Hans" or CJK.search(key)):
                    continue
                missing[lang] += 1
                problems.append(f"{path.name}: [{lang}] missing: {key!r}")
                continue
            leaves = units(loc)
            if not leaves:
                missing[lang] += 1
                problems.append(f"{path.name}: [{lang}] no value: {key!r}")
                continue
            for where, unit in leaves:
                value = unit.get("value", "")
                state = unit.get("state", "")
                if not value.strip() or state not in ("translated", ""):
                    missing[lang] += 1
                    problems.append(f"{path.name}: [{lang}] {where} state={state or '-'} empty={not value.strip()}: {key!r}")
                    break
                # An English source copied verbatim into another language is
                # an untranslated string, unless it's on the allowlist
                # (brand names, abbreviations, units).
                if (lang != "en" and english_text is not None
                        and value.strip() == english_text.strip()
                        and LATIN_WORDS.search(SPECIFIER.sub("", value))
                        and value.strip() not in KEEP_AS_IS
                        and value.strip() not in keep_for(lang)):
                    missing[lang] += 1
                    problems.append(f"{path.name}: [{lang}] {where} identical to the English source: {key!r}")
                    break
                # Plural variants may legitimately drop the count ("one" → "a").
                if "plural." not in where and specifiers(value) != source_specs:
                    missing[lang] += 1
                    problems.append(f"{path.name}: [{lang}] {where} specifiers {specifiers(value)} != {source_specs}: {key!r}")
                    break

    return total, missing, problems


def main(argv: list[str]) -> int:
    verbose = "--verbose" in argv
    paths = [Path(a) for a in argv if not a.startswith("--")]
    if not paths:
        paths = sorted(
            p for d in SEARCH_DIRS for p in (ROOT / d).rglob("*.xcstrings")
            if "BuiltinSkills" not in p.parts
        )
    ok = True
    for path in paths:
        total, missing, problems = check_catalog(path, verbose)
        worst = max(missing.values()) if missing else 0
        ok &= worst == 0
        rel = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
        print(f"{rel}: {total} keys")
        for lang in LANGUAGES:
            done = total - missing[lang]
            pct = 100.0 * done / total if total else 100.0
            print(f"  {lang:8s} {done:5d}/{total:<5d} {pct:6.2f}%")
        if problems and verbose:
            print("\n".join("    " + p for p in problems))
        elif problems:
            print(f"  {len(problems)} problem(s); rerun with --verbose to list them")
    print("OK: every catalog is fully translated" if ok else "FAIL: untranslated strings remain")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
