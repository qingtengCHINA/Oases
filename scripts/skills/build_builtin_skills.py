#!/usr/bin/env python3
"""Vendor the OpenMinis/MinisSkills repository as Ogent built-in skills.

Usage:
    python3 scripts/skills/build_builtin_skills.py <upstream-checkout> <commit> [--out DIR]

Copies every top-level skill folder (a directory containing SKILL.md) of an
upstream MinisSkills checkout into `OasesChat/Resources/BuiltinSkills/<id>/`
and writes `LICENSE`, `NOTICE` and `manifest.json` next to them. Upstream
content is copied as is, except EXCLUDED_SKILLS (not vendored) and
TEXT_OVERRIDES (exact replacements applied to the copy before hashing). The app's
`BuiltinSkillSynchronizer` installs/updates the skills from that manifest.

Reproducible: the output depends only on the upstream tree at <commit>.
Everything is sorted, hashes are SHA-256 hex, JSON is UTF-8 with a trailing
newline. When the checkout is a git repo, HEAD must equal <commit>.

Hash definitions (the app only compares them, it never recomputes them):
    contentHash = sha256( "".join(f"{relpath}\\0{file_sha}\\n" for sorted files) )
    bundleHash  = sha256( "".join(f"{id}\\0{contentHash}\\n"   for sorted skills) )

Standard library only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

UPSTREAM_REPO = "https://github.com/OpenMinis/MinisSkills"

# Top-level entries of the upstream repo that are not skills.
NON_SKILL_TOP_LEVEL = {"scripts", ".git", ".github"}

# Never vendored, at any depth.
EXCLUDED_NAMES = {".git", ".DS_Store", "__pycache__"}
EXCLUDED_SUFFIXES = (".pyc", ".pyo")

# Not vendored: ChatGPT-account features whose visible text is branded throughout (mainland-China App Store),
# and skills that need a capability the app does not ship.
EXCLUDED_SKILLS = {
    "codex-image": "ChatGPT-account image generation; branded throughout (App Store, mainland China)",
    "codex-on-ish": "OpenAI Codex CLI with ChatGPT login; branded throughout (App Store, mainland China)",
    "health-sleep-analysis": "reads HealthKit sleep data; the app no longer ships HealthKit (App Review 5.6, 2026-10-08)",
}

# Skills installed but switched off by default, with the reason shown in the UI.
DEFAULT_DISABLED = {
    "android-dev": "仅适用于 Minis Android（需 Shizuku/Android SDK），iOS 上不可用",
    "android-ui-automation": "仅适用于 Minis Android（需 Android 无障碍服务），iOS 上不可用",
    "hyperframes": "需要 Chrome 与 Node ≥ 22，iSH 环境无法运行",
}

# Exact text replacements in the vendored copy: {skill id: {relpath: [(old, new)]}}.
# Each `old` must occur exactly once, so an upstream change fails the build
# instead of silently skipping. Used to keep text users see in the Skills UI
# (description, detail preview, examples) free of the OpenAI / ChatGPT / GPT
# brand; scripts/check_forbidden_brands.sh checks the result. Never used on
# code that calls real endpoints.
TEXT_OVERRIDES: dict[str, dict[str, list[tuple[str, str]]]] = {
    "appstoreprice-hub": {
        "SKILL.md": [
            ("(such as ChatGPT Plus/Pro, Claude Pro/Max, etc.)",
             "(such as Spotify Premium Individual/Family, Claude Pro/Max, etc.)"),
            ("const sr = await asp.search('ChatGPT');",
             "const sr = await asp.search('Spotify');"),
        ],
    },
    "xianyu-hub": {
        "SKILL.md": [
            ('sh scripts/smart_search.sh -k "gpt plus"',
             'sh scripts/smart_search.sh -k "Spotify premium"'),
            ('sh scripts/alt_keywords.sh -q "gpt" -j',
             'sh scripts/alt_keywords.sh -q "spotify" -j'),
        ],
    },
}

DEFAULT_VERSION = "1.0.0"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def content_hash(files: dict[str, str]) -> str:
    return sha256_text("".join(f"{rel}\0{sha}\n" for rel, sha in sorted(files.items())))


def bundle_hash(skills: list[dict]) -> str:
    pairs = sorted((s["id"], s["contentHash"]) for s in skills)
    return sha256_text("".join(f"{sid}\0{chash}\n" for sid, chash in pairs))


def parse_frontmatter(skill_md: Path) -> dict[str, str]:
    """Top-level scalar `key: value` pairs of the leading `---` block."""
    lines = skill_md.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    result: dict[str, str] = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if not line or line[0].isspace() or ":" not in line:
            continue
        key, _, value = line.partition(":")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        result[key.strip().lower()] = value
    return result


def apply_text_overrides(path: Path, replacements: list[tuple[str, str]]) -> None:
    """Apply exact, once-only replacements to a vendored file in place."""
    text = path.read_text(encoding="utf-8")
    for old, new in replacements:
        found = text.count(old)
        if found != 1:
            raise SystemExit(f"error: override text found {found}x (expected 1) in {path}: {old!r}")
        text = text.replace(old, new)
    path.write_text(text, encoding="utf-8")


def is_excluded(name: str) -> bool:
    return name in EXCLUDED_NAMES or name.endswith(EXCLUDED_SUFFIXES)


def list_skill_files(skill_dir: Path) -> list[str]:
    """Sorted POSIX relpaths of every regular file under `skill_dir`."""
    rels: list[str] = []
    for root, dirs, files in os.walk(skill_dir):
        dirs[:] = sorted(d for d in dirs if not is_excluded(d))
        root_path = Path(root)
        for name in files:
            if is_excluded(name):
                continue
            path = root_path / name
            if path.is_symlink() or not path.is_file():
                raise SystemExit(f"error: unsupported non-regular file {path}")
            rels.append(path.relative_to(skill_dir).as_posix())
    return sorted(rels)


def verify_commit(upstream: Path, commit: str) -> None:
    if not (upstream / ".git").exists():
        print(f"warning: {upstream} is not a git checkout; cannot verify commit", file=sys.stderr)
        return
    head = subprocess.run(
        ["git", "-C", str(upstream), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    if head != commit:
        raise SystemExit(f"error: upstream HEAD is {head}, expected {commit}")
    dirty = subprocess.run(
        ["git", "-C", str(upstream), "status", "--porcelain"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    if dirty:
        raise SystemExit("error: upstream checkout has local modifications")


def discover_skills(upstream: Path) -> list[str]:
    ids = []
    for entry in sorted(upstream.iterdir()):
        if not entry.is_dir() or entry.name.startswith(".") or entry.name in NON_SKILL_TOP_LEVEL:
            continue
        if (entry / "SKILL.md").is_file() and entry.name not in EXCLUDED_SKILLS:
            ids.append(entry.name)
    return ids


NOTICE_TEMPLATE = """Oases Chat built-in skills

The skills in this directory are vendored from:

  Repository: {repo}
  Commit:     {commit}

Copyright (c) 2026 OpenMinis and contributors.

Not vendored (EXCLUDED_SKILLS): {excluded}.
Modified (TEXT_OVERRIDES, exact text replacements): {overridden}.
Everything else is unmodified.

License: the upstream LICENSE file (copied alongside as LICENSE) is the MIT
License. The upstream README additionally states "Apache License 2.0"; the
LICENSE file is reproduced verbatim and both notices are preserved here.

Regenerate with:
  python3 scripts/skills/build_builtin_skills.py <MinisSkills checkout> {commit}
"""


def build(upstream: Path, commit: str, out_dir: Path) -> dict:
    skill_ids = discover_skills(upstream)
    unknown_disabled = sorted(set(DEFAULT_DISABLED) - set(skill_ids))
    if unknown_disabled:
        raise SystemExit(f"error: default-disabled ids not found upstream: {unknown_disabled}")
    unknown_overrides = sorted(set(TEXT_OVERRIDES) - set(skill_ids))
    if unknown_overrides:
        raise SystemExit(f"error: text-override ids not found upstream: {unknown_overrides}")
    stale_exclusions = sorted(i for i in EXCLUDED_SKILLS if not (upstream / i / "SKILL.md").is_file())
    if stale_exclusions:
        raise SystemExit(f"error: excluded ids not found upstream: {stale_exclusions}")

    out_dir.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".BuiltinSkills-", dir=out_dir.parent))
    staging.chmod(0o755)  # mkdtemp creates 0700
    try:
        skills = []
        for skill_id in skill_ids:
            src = upstream / skill_id
            files: dict[str, str] = {}
            rels = list_skill_files(src)
            overrides = TEXT_OVERRIDES.get(skill_id, {})
            missing = sorted(set(overrides) - set(rels))
            if missing:
                raise SystemExit(f"error: text-override files not found in {skill_id}: {missing}")
            for rel in rels:
                dest = staging / skill_id / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src / rel, dest)
                shutil.copymode(src / rel, dest)
                if rel in overrides:
                    apply_text_overrides(dest, overrides[rel])
                files[rel] = sha256_file(dest)
            meta = parse_frontmatter(staging / skill_id / "SKILL.md")
            skills.append({
                "id": skill_id,
                "name": meta.get("name") or skill_id,
                "version": meta.get("version") or DEFAULT_VERSION,
                "defaultEnabled": skill_id not in DEFAULT_DISABLED,
                "disabledReason": DEFAULT_DISABLED.get(skill_id),
                "contentHash": content_hash(files),
                "files": dict(sorted(files.items())),
            })

        manifest = {
            "schemaVersion": 1,
            "upstream": {"repo": UPSTREAM_REPO, "commit": commit},
            "bundleHash": bundle_hash(skills),
            "skills": skills,
        }
        (staging / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        shutil.copyfile(upstream / "LICENSE", staging / "LICENSE")
        excluded = ", ".join(sorted(EXCLUDED_SKILLS)) or "none"
        overridden = ", ".join(
            f"{sid}/{rel}" for sid, files in sorted(TEXT_OVERRIDES.items()) for rel in sorted(files)
        ) or "none"
        (staging / "NOTICE").write_text(
            NOTICE_TEMPLATE.format(repo=UPSTREAM_REPO, commit=commit, excluded=excluded, overridden=overridden),
            encoding="utf-8",
        )

        if out_dir.exists():
            retire(out_dir)
        staging.rename(out_dir)
        return manifest
    except BaseException:
        if staging.exists():
            retire(staging)
        raise


def retire(path: Path) -> None:
    """Move a previous output out of the way (to ~/.Trash when available)."""
    trash = Path.home() / ".Trash"
    if trash.is_dir():
        target = trash / f"{path.name}-{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"
        shutil.move(str(path), str(target))
    else:
        shutil.rmtree(path)


def main() -> int:
    default_out = Path(__file__).resolve().parents[2] / "OasesChat" / "Resources" / "BuiltinSkills"
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("upstream", type=Path, help="path to a MinisSkills checkout")
    parser.add_argument("commit", help="upstream commit SHA the checkout is at")
    parser.add_argument("--out", type=Path, default=default_out, help=f"output dir (default: {default_out})")
    args = parser.parse_args()

    upstream = args.upstream.resolve()
    if not (upstream / "LICENSE").is_file():
        raise SystemExit(f"error: {upstream} does not look like a MinisSkills checkout")
    verify_commit(upstream, args.commit)

    manifest = build(upstream, args.commit, args.out.resolve())
    enabled = sum(1 for s in manifest["skills"] if s["defaultEnabled"])
    files = sum(len(s["files"]) for s in manifest["skills"])
    print(f"wrote {len(manifest['skills'])} skills ({enabled} enabled by default, {files} files) "
          f"to {args.out}")
    print(f"bundleHash {manifest['bundleHash']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
