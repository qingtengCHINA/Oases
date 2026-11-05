#!/usr/bin/env python3
"""Translation plumbing around `xcodebuild -exportLocalizations` output.

  xliff_tool.py worklist <export_dir> <lang> <out.json> [--seed seed.json ...] [--all]
      Units of <lang>.xcloc that still need a translation, as JSON:
      [{"file", "id", "source", "note", "hints": {"en": ..., "<lang>": ...}}].
      Units whose source has no letters ("%lld", "00:00", "·") are skipped:
      `apply` fills them with the source. With --all, units that already have
      a target are included too.

  xliff_tool.py apply <export_dir> <lang> <translations.json> [--seed seed.json ...]
      Writes targets into <lang>.xcloc: translations.json maps unit id (or
      "file|id" when an id repeats across catalogs) to text. Seed values for
      <lang> fill units the translations don't cover. Every target must keep
      the source's format specifiers; offending units are reported and left
      untouched. Then import with `xcodebuild -importLocalizations`.

  xliff_tool.py pair <worklist.json> <zh-Hans.json> <en.json> <out.json> [--xliff-dir <export_dir>]
      Adds "zh" and "en" to every unit of a round-2 worklist: the source when
      it's already in that language, else the round-1 translation, else (with
      --xliff-dir) the target already in the zh-Hans/en export.

  xliff_tool.py write <lang> <translations.json> <worklist.json>
      Writes translations straight into the project's String Catalogs (and
      <lang>.lproj copies of legacy .strings files). Use this instead of
      `xcodebuild -importLocalizations`, which re-extracts without the Swift
      compiler, treats code-defined keys as missing and deletes them. Also
      fills letter-less strings ("%lld", "00:00") with their source text.

Seed files map a catalog key to {"<lang>": "<text>", ...} (scripts/i18n/seed/).
"""
from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

NS = "urn:oasis:names:tc:xliff:document:1.2"
ET.register_namespace("", NS)
Q = lambda tag: f"{{{NS}}}{tag}"  # noqa: E731

SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h|hh|z|t|j|L)?[@dDuUxXoOfeEgGcCsSpaAi]")
CJK = re.compile(r"[\u4e00-\u9fff]")
HAS_WORDS = re.compile(r"[A-Za-zÀ-ɏЀ-ӿ぀-ヿ一-鿿가-힯]")


def specifiers(text: str) -> list[str]:
    return sorted(re.sub(r"%\d+\$", "%", s) for s in SPECIFIER.findall(text.replace("%%", "")))


def xliff_path(export_dir: Path, lang: str) -> Path:
    return export_dir / f"{lang}.xcloc" / "Localized Contents" / f"{lang}.xliff"


def load_seeds(paths: list[str]) -> dict[str, dict[str, str]]:
    merged: dict[str, dict[str, str]] = {}
    for p in paths:
        for key, langs in json.loads(Path(p).read_text(encoding="utf-8")).items():
            merged.setdefault(key, {}).update({k: v for k, v in langs.items() if isinstance(v, str) and v.strip()})
    return merged


def units(tree: ET.ElementTree):
    for f in tree.getroot().iter(Q("file")):
        original = f.get("original", "")
        for tu in f.iter(Q("trans-unit")):
            yield original, tu


def text_of(tu: ET.Element, tag: str) -> str:
    el = tu.find(Q(tag))
    return (el.text or "") if el is not None else ""


def split_args(argv: list[str]) -> tuple[list[str], list[str], bool]:
    positional, seeds, flag_all = [], [], False
    i = 0
    while i < len(argv):
        if argv[i] == "--seed":
            seeds.append(argv[i + 1])
            i += 2
        elif argv[i] == "--all":
            flag_all = True
            i += 1
        else:
            positional.append(argv[i])
            i += 1
    return positional, seeds, flag_all


def worklist(argv: list[str]) -> int:
    (export_dir, lang, out), seeds_paths, include_all = split_args(argv)[0], split_args(argv)[1], split_args(argv)[2]
    seeds = load_seeds(seeds_paths)
    tree = ET.parse(xliff_path(Path(export_dir), lang))
    ids = [tu.get("id") for _, tu in units(tree)]
    duplicated = {i for i in ids if ids.count(i) > 1}
    items = []
    for original, tu in units(tree):
        uid, source = tu.get("id"), text_of(tu, "source")
        if not HAS_WORDS.search(source):
            continue
        target = text_of(tu, "target").strip()
        # The source-language export pre-fills target = source, so an
        # English-keyed string would stay English for zh-Hans users.
        untranslated_source = lang.startswith("zh") and target == source.strip() and not CJK.search(source)
        if not include_all and target and not untranslated_source:
            continue
        hints = {k: v for k, v in seeds.get(uid, {}).items() if k in ("en", lang)}
        items.append({
            "key": f"{original}|{uid}" if uid in duplicated else uid,
            "file": original,
            "source": source,
            "note": text_of(tu, "note"),
            "hints": hints,
        })
    Path(out).write_text(json.dumps(items, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"{lang}: {len(items)} unit(s) to translate → {out}")
    return 0


def apply(argv: list[str]) -> int:
    (export_dir, lang, translations_path), seeds_paths, _ = split_args(argv)
    seeds = load_seeds(seeds_paths)
    translations = json.loads(Path(translations_path).read_text(encoding="utf-8"))
    path = xliff_path(Path(export_dir), lang)
    tree = ET.parse(path)
    written = kept = missing = bad = 0
    problems = []
    for original, tu in units(tree):
        uid, source = tu.get("id"), text_of(tu, "source")
        value = translations.get(f"{original}|{uid}", translations.get(uid))
        if value is None:
            value = seeds.get(uid, {}).get(lang)
        if value is None and not HAS_WORDS.search(source):
            value = source
        if value is None:
            if text_of(tu, "target").strip():
                kept += 1
            else:
                missing += 1
                problems.append(f"missing: {uid!r}")
            continue
        if specifiers(value) != specifiers(source):
            bad += 1
            problems.append(f"specifiers {specifiers(value)} != {specifiers(source)}: {uid!r} → {value!r}")
            continue
        target = tu.find(Q("target"))
        if target is None:
            target = ET.Element(Q("target"))
            # <target> goes right after <source>.
            children = list(tu)
            index = next((i for i, c in enumerate(children) if c.tag == Q("source")), 0) + 1
            tu.insert(index, target)
        target.text = value
        target.set("state", "translated")
        written += 1
    tree.write(path, encoding="UTF-8", xml_declaration=True)
    print(f"{lang}: wrote {written}, kept {kept}, missing {missing}, bad specifiers {bad}")
    for p in problems[:40]:
        print("  " + p)
    if len(problems) > 40:
        print(f"  … {len(problems) - 40} more")
    return 0 if not (missing or bad) else 1


def existing_targets(export_dir: Path, lang: str) -> dict[str, str]:
    """Targets already in <lang>.xcloc, keyed like worklist keys."""
    tree = ET.parse(xliff_path(export_dir, lang))
    ids = [tu.get("id") for _, tu in units(tree)]
    out: dict[str, str] = {}
    for original, tu in units(tree):
        target = text_of(tu, "target")
        if target.strip():
            out[tu.get("id")] = target
            out[f"{original}|{tu.get('id')}"] = target
    return out


def pair(argv: list[str]) -> int:
    positional = [a for a in argv if not a.startswith("--")]
    work_path, zh_path, en_path, out = positional[:4]
    work = json.loads(Path(work_path).read_text(encoding="utf-8"))
    zh = json.loads(Path(zh_path).read_text(encoding="utf-8"))
    en = json.loads(Path(en_path).read_text(encoding="utf-8"))
    if "--xliff-dir" in argv:
        export_dir = Path(argv[argv.index("--xliff-dir") + 1])
        zh = {**existing_targets(export_dir, "zh-Hans"), **zh}
        en = {**existing_targets(export_dir, "en"), **en}
    missing = 0
    for unit in work:
        key, source = unit["key"], unit["source"]
        chinese = bool(CJK.search(source))
        unit["zh"] = source if chinese else zh.get(key)
        unit["en"] = en.get(key) if chinese else en.get(key, source)
        if unit["zh"] is None or unit["en"] is None:
            missing += 1
    Path(out).write_text(json.dumps(work, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"{len(work)} unit(s) paired, {missing} missing a zh/en side → {out}")
    return 1 if missing else 0


def write(argv: list[str]) -> int:
    import xcstrings_io  # sibling module
    lang, translations_path, worklist_path = argv[:3]
    translations = json.loads(Path(translations_path).read_text(encoding="utf-8"))
    work = json.loads(Path(worklist_path).read_text(encoding="utf-8"))
    root = Path(__file__).resolve().parents[2]
    catalogs: dict[str, dict] = {}
    legacy: dict[str, dict[str, str]] = {}
    written = unknown = 0
    problems = []
    for unit in work:
        key, file = unit["key"], unit["file"]
        uid = key.split("|", 1)[1] if key.startswith(file + "|") else key
        value = translations.get(key)
        if value is None:
            problems.append(f"no translation: {key!r}")
            continue
        if specifiers(value) != specifiers(unit["source"]):
            problems.append(f"specifiers: {key!r} → {value!r}")
            continue
        if file.endswith(".xcstrings"):
            if file not in catalogs:
                catalogs[file] = xcstrings_io.load(root / file)
            catalog = catalogs[file]
            entry = catalog["strings"].get(uid)
            if entry is None:
                unknown += 1
                problems.append(f"not in catalog {file}: {uid!r}")
                continue
            existing = entry.setdefault("localizations", {}).get(lang, {})
            if "variations" in existing:
                continue
            entry["localizations"][lang] = {"stringUnit": {"state": "translated", "value": value}}
            written += 1
        elif file.endswith(".strings") and "zh-Hans.lproj" in file and not (root / file).exists():
            # Xcode synthesizes e.g. AppShortcuts.strings from code at export
            # time; the real home for its translations is a sibling catalog
            # (AppShortcuts.xcstrings), which covers every language.
            catalog_file = str(Path(file).parent.parent / (Path(file).stem + ".xcstrings"))
            if catalog_file not in catalogs:
                path = root / catalog_file
                catalogs[catalog_file] = xcstrings_io.load(path) if path.exists() else {
                    "sourceLanguage": "zh-Hans", "strings": {}, "version": "1.0"}
            entry = catalogs[catalog_file]["strings"].setdefault(uid, {"extractionState": "manual"})
            entry.setdefault("localizations", {})[lang] = {"stringUnit": {"state": "translated", "value": value}}
            written += 1
        elif file.endswith(".strings") and "zh-Hans.lproj" in file:
            if lang != "zh-Hans":
                legacy.setdefault(file.replace("zh-Hans.lproj", f"{lang}.lproj"), {})[uid] = value
                written += 1
        else:
            problems.append(f"unsupported file {file}: {uid!r}")
    # Letter-less strings read the same everywhere; give every catalog a value
    # so coverage is complete.
    filled = 0
    for file in {u["file"] for u in work if u["file"].endswith(".xcstrings")}:
        if file not in catalogs:
            catalogs[file] = xcstrings_io.load(root / file)
        catalog = catalogs[file]
        for uid, entry in catalog["strings"].items():
            locs = entry.get("localizations") or {}
            if lang in locs or entry.get("shouldTranslate") is False:
                continue
            source_units = locs.get(catalog.get("sourceLanguage", "zh-Hans"), {}).get("stringUnit", {})
            source = source_units.get("value", uid)
            if source.strip() and not HAS_WORDS.search(source):
                entry.setdefault("localizations", {})[lang] = {"stringUnit": {"state": "translated", "value": source}}
                filled += 1
    for file, catalog in catalogs.items():
        xcstrings_io.save(root / file, catalog)
    for file, pairs in legacy.items():
        path = root / file
        path.parent.mkdir(parents=True, exist_ok=True)
        esc = lambda t: t.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")  # noqa: E731
        path.write_text("".join(f'"{esc(k)}" = "{esc(v)}";\n' for k, v in sorted(pairs.items())), encoding="utf-8")
    print(f"{lang}: wrote {written}, filled {filled} letter-less, {unknown} not in catalog, {len(problems)} problem(s)")
    for p in problems[:30]:
        print("  " + p)
    return 0 if not problems else 1


def main(argv: list[str]) -> int:
    commands = {"worklist": worklist, "apply": apply, "pair": pair, "write": write}
    if len(argv) < 1 or argv[0] not in commands:
        print(__doc__)
        return 2
    return commands[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
