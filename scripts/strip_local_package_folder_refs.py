#!/usr/bin/env python3
"""Remove XcodeGen local-package navigator folder refs from project.pbxproj.

XcodeGen writes both:
  1) XCLocalSwiftPackageReference  (needed for SPM resolve/link)
  2) PBXFileReference + Packages group folder refs to vendor/spm/*

Folder refs make Xcode open nested `.swiftpm/xcode` stubs and report:
  Couldn't load project "xcode"
which then cascades into Missing package product for the same packages.

This script keeps (1) and deletes (2).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


def strip(pbxproj: Path) -> int:
    text = pbxproj.read_text(encoding="utf-8")
    original = text

    # Collect PBXFileReference IDs whose path is under vendor/spm/
    file_ref_re = re.compile(
        r"^\t\t([0-9A-F]{24}) /\* .+ \*/ = \{isa = PBXFileReference; "
        r"lastKnownFileType = folder; name = .+; "
        r'path = "?vendor/spm/[^";]+"?; sourceTree = SOURCE_ROOT; \};$',
        re.MULTILINE,
    )
    file_ref_ids = [m.group(1) for m in file_ref_re.finditer(text)]
    if not file_ref_ids:
        print("strip_local_package_folder_refs: no vendor/spm folder refs found")
        return 0

    # Drop the file reference lines
    text = file_ref_re.sub("", text)

    # Drop children entries that point at those IDs
    for rid in file_ref_ids:
        text = re.sub(
            rf"^\t\t\t\t{rid} /\* .+ \*/,\n",
            "",
            text,
            flags=re.MULTILINE,
        )

    # Drop empty Packages group if it only had those children
    packages_group_re = re.compile(
        r"\t\t[0-9A-F]{24} /\* Packages \*/ = \{\n"
        r"\t\t\tisa = PBXGroup;\n"
        r"\t\t\tchildren = \(\n"
        r"\t\t\t\);\n"
        r"\t\t\tname = Packages;\n"
        r'\t\t\tsourceTree = "<group>";\n'
        r"\t\t\};\n",
        re.MULTILINE,
    )
    text2, n_empty = packages_group_re.subn("", text)
    text = text2

    # Drop Packages group membership from parent groups
    text = re.sub(
        r"^\t\t\t\t[0-9A-F]{24} /\* Packages \*/,\n",
        "",
        text,
        flags=re.MULTILINE,
    )

    if text == original:
        print("strip_local_package_folder_refs: no changes applied")
        return 0

    pbxproj.write_text(text, encoding="utf-8")
    print(
        f"strip_local_package_folder_refs: removed {len(file_ref_ids)} folder ref(s)"
        + (f", dropped empty Packages group x{n_empty}" if n_empty else "")
    )
    return len(file_ref_ids)


def bump_last_upgrade_check(pbxproj: Path) -> None:
    """Pin LastUpgradeCheck to the Xcode in use so the IDE stops offering
    "Update to recommended settings" after every XcodeGen regeneration.
    XcodeGen has no option for this and emits an ancient default (1430)."""
    text = pbxproj.read_text(encoding="utf-8")
    new_text, n = re.subn(r"LastUpgradeCheck = \d+;", "LastUpgradeCheck = 2700;", text)
    if n:
        pbxproj.write_text(new_text, encoding="utf-8")
        print(f"strip_local_package_folder_refs: LastUpgradeCheck pinned to 2700 ({n} site(s))")
    else:
        print("strip_local_package_folder_refs: LastUpgradeCheck not found")


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    pbx = root / "OasesChat.xcodeproj" / "project.pbxproj"
    if not pbx.is_file():
        print(f"error: missing {pbx}", file=sys.stderr)
        return 1
    strip(pbx)
    bump_last_upgrade_check(pbx)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
