#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate a measured (not hand-written) OpenMinis -> OasesChat port inventory.

Why this exists
---------------
`docs/openminis-port-audit.md` and `docs/migration-progress.md` are hand-maintained
and drift away from the code within days. Every number in the generated report is
derived from the working tree at run time, so it cannot drift.

Design constraints
------------------
* python3 standard library only, no third-party imports.
* Read-only: never mutates the repo, only writes the single --out file.
* Every mapping that cannot be derived mechanically (because the two trees are not
  isomorphic) is declared explicitly in MODULE_MAP below, so a reader can audit the
  mapping itself instead of trusting it.
* Anything the script cannot match confidently is reported as a WARNING rather than
  being silently dropped. Silence is the failure mode this script exists to kill.

Usage
-----
    python3 scripts/gen_port_inventory.py
    python3 scripts/gen_port_inventory.py --out docs/port-inventory.generated.md
    python3 scripts/gen_port_inventory.py --openminis /path/to/OpenMinis/src/ios
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys
from pathlib import Path

# --------------------------------------------------------------------------- #
# Paths / constants
# --------------------------------------------------------------------------- #

REPO_ROOT = Path(__file__).resolve().parent.parent

DEFAULT_OPENMINIS = (
    REPO_ROOT.parent.parent / "OpenMinis" / "src" / "ios"
)

DEFAULT_OUT = REPO_ROOT / "docs" / "port-inventory.generated.md"

SWIFT_EXT = {".swift"}
CFAMILY_EXT = {".m", ".mm", ".h", ".c", ".cpp", ".hpp", ".cc"}
CODE_EXT = SWIFT_EXT | CFAMILY_EXT

# Directory names never counted as project source on either side.
PRUNE_DIRS = {
    ".git",
    ".build",
    "build",
    "DerivedData",
    "Pods",
    "node_modules",
    ".shots",
    ".zcode",
    "Preview Content",
    "Assets.xcassets",
    "default_mount",
    "__pycache__",
}

PRUNE_SUFFIXES = (".xcodeproj", ".xcworkspace", ".xcassets", ".lproj", ".bundle")


# --------------------------------------------------------------------------- #
# Module landing map — the one thing that CANNOT be derived mechanically.
#
# The two trees are not isomorphic (OpenMinis groups by `Agent/*` + `Views/*`;
# OasesChat groups by `Services/*` + `Features/*`), so the correspondence is
# declared here on purpose and is itself part of the reviewable output.
#
# Each entry: (openminis_relpath, [oaseschat_relpaths], note)
# An empty target list means "deliberately not ported / no counterpart".
# --------------------------------------------------------------------------- #

MODULE_MAP: list[tuple[str, list[str], str]] = [
    # ---- Agent/* -> Services/* ------------------------------------------- #
    ("Agent/Background", ["OasesChat/Services/Agent/Background"], "同名落点"),
    (
        "Agent/BrowserUse",
        ["OasesChat/Services/Browser/BrowserUse"],
        "重分类：从 Agent/ 挪到 Services/Browser/",
    ),
    ("Agent/Chat", ["OasesChat/Services/Agent/Chat"], "同名落点"),
    ("Agent/ISH", ["OasesChat/Services/Agent/ISH"], "同名落点"),
    (
        "Agent/Intents",
        ["OasesChat/Services/Agent/Intents"],
        "同名落点；OpenMinis 的 ListSessions/OpenSession/GetSessionStatus/ShortcutsProvider "
        "四个文件被合并进 `SessionIntents.swift`，故文件数偏少不等于功能缺失",
    ),
    ("Agent/Markdown", ["OasesChat/Services/Agent/Markdown"], "同名落点"),
    ("Agent/MessageList", ["OasesChat/Services/Agent/MessageList"], "同名落点"),
    (
        "Agent/Offload",
        ["OasesChat/Services/Agent/Offloads"],
        "单数 Offload -> 复数 Offloads；OasesChat 侧多出各 *OffloadBridge.swift",
    ),
    ("Agent/Session", ["OasesChat/Services/Agent/Session"], "同名落点"),
    ("Agent/Shell", ["OasesChat/Services/Agent/Shell"], "同名落点"),
    (
        "Agent/Speech",
        ["OasesChat/Services/Speech"],
        "提级：Agent/Speech -> Services/Speech（Services/Agent/Speech 是空壳残留目录）",
    ),
    ("Agent/Sync", ["OasesChat/Services/Sync"], "提级：Agent/Sync -> Services/Sync"),
    (
        "Agent",
        ["OasesChat/Services/Agent"],
        "Agent/ 顶层散文件 -> Services/Agent 顶层（仅比对 depth=1）",
    ),
    # ---- Views/* -> Features/* ------------------------------------------- #
    ("Views/Alarms", ["OasesChat/Features/Alarms"], "Views -> Features"),
    ("Views/Backup", ["OasesChat/Features/Backup"], "Views -> Features"),
    ("Views/Chat", ["OasesChat/Features/Chat"], "Views -> Features"),
    ("Views/MCP", ["OasesChat/Features/MCP"], "Views -> Features"),
    ("Views/Providers", ["OasesChat/Features/Providers"], "Views -> Features"),
    ("Views/Rootfs", ["OasesChat/Features/Rootfs"], "Views -> Features"),
    ("Views/Settings", ["OasesChat/Features/Settings"], "Views -> Features"),
    ("Views/Skills", ["OasesChat/Features/Skills"], "Views -> Features"),
    ("Views/Sync", ["OasesChat/Features/Sync"], "Views -> Features"),
    # ---- top-level modules ----------------------------------------------- #
    ("Providers", ["OasesChat/Services/Providers"], "同名落点"),
    (
        "Shared/Config",
        ["OasesChat/Services/Config"],
        "提级：Shared/Config -> Services/Config",
    ),
    (
        "Shared/Environment",
        ["OasesChat/Services/Shared"],
        "并入 Services/Shared（单文件 ChatSessionIdEnvironment.swift）",
    ),
    (
        "Shared",
        [
            "OasesChat/Services/Shared",
            "vendor/iSH/shared",
            "vendor/iSH/support",
        ],
        "depth=1：Swift 落 Services/Shared，ObjC 安全垫片（SafeKVCSetTrue / "
        "NSTextContainerSetSizeGuard / ObjCExceptionCatcher / FileHandleSafeWrite / "
        "JiebaWrapper）落 vendor/iSH/{shared,support}",
    ),
    (
        "Debug",
        [
            "OasesChat/Services/Debug",
            "OasesChat/Features/Debug",
            "vendor/iSH/diagnostics",
        ],
        "服务/界面拆分；ObjC 探针（AttributeQueryRecorder / AutoTouch / HangDetector）"
        "落 vendor/iSH/diagnostics（与 Diagnostics 行共享该目录，故两行都列出）",
    ),
    (
        "Diagnostics",
        ["OasesChat/Services/Diagnostics", "vendor/iSH/diagnostics"],
        "Swift 落 Services/Diagnostics；`CrashSignalHandler.h/.m` 落 vendor/iSH/diagnostics",
    ),
    ("FileProvider", ["OasesChat/Services/FileProvider", "Extensions/FileProvider"], "宿主服务 + App Extension 拆分"),
    ("WebApp", ["OasesChat/Features/WebApp"], "-> Features/WebApp"),
    ("Configs", ["Configuration"], "仅 ProviderCustomization.xcconfig.example -> Configuration/"),
    (
        "NativeOffloads",
        ["vendor/iSH/offloads", "OasesChat/Services/Agent/Offloads"],
        "ObjC 落 vendor/iSH/offloads；*OffloadBridge.swift 落 Services/Agent/Offloads",
    ),
    (
        "iSH",
        ["vendor/iSH/runtime", "OasesChat/Services/ISH", "OasesChat/Features/Terminal"],
        "内核胶水 / 服务层 / 终端 UI 三分",
    ),
    ("AgentWidget", ["Extensions/AgentWidget"], "App Extension 独立目录"),
    ("ShareExtension", ["Extensions/ShareExtension"], "App Extension 独立目录"),
    ("MinisTests", ["OasesChatTests"], "测试 target 更名"),
    ("MinisUITests", ["OasesChatUITests"], "UI 测试 target 更名"),
    ("Vendor", ["vendor"], "第三方源码"),
    ("Resources", ["OasesChat/Resources"], "同名落点"),
]

# Single files at the OpenMinis root (or a root that holds a single loose file)
# that map to a renamed / split OasesChat file. A note starting with "真实缺口"
# combined with an empty target list is escalated into a generation warning.
FILE_MAP: list[tuple[str, list[str], str]] = [
    ("MinisApp.swift", ["OasesChat/App/OasesChatApp.swift", "OasesChat/App/RootView.swift"], "App 入口 -> 拆分到 App/"),
    (
        "Views/ContentView.swift",
        ["OasesChat/App/RootView.swift", "OasesChat/Features/Sidebar"],
        "Views/ 唯一顶层文件；5.4k 行 -> RootView + Sidebar，行数显著瘦身，需人工确认取舍",
    ),
    ("AppDelegate.swift", ["OasesChat/App/OasesAppDelegate.swift"], "更名"),
    ("MinisApp-Bridging-Header.h", ["OasesChat/OasesChat-Bridging-Header.h"], "更名"),
    ("Minis.entitlements", ["OasesChat/OasesChat.entitlements"], "更名"),
    ("Info.plist", ["OasesChat/Resources/Info.plist"], "移入 Resources/"),
    ("Localizable.xcstrings", ["OasesChat/Localization/Localizable.xcstrings"], "移入 Localization/"),
    (
        "ISHCommandExecutionExample.swift",
        [],
        "示例代码，未移植（OasesChat 用 Services/ISH/ISHCommand*.swift 承接）",
    ),
    (
        "PrivacyInfo.xcprivacy",
        [],
        "真实缺口：OasesChat 全仓无 `PrivacyInfo.xcprivacy`，project.yml 里也没有引用 —— "
        "App Store 隐私清单缺失，上架前必须补",
    ),
    ("Launch Screen.storyboard", ["OasesChat/Features/Launch"], "storyboard -> SwiftUI Launch 特性目录"),
]

# Scale buckets: (label, side, [relpaths])
SCALE_BUCKETS_OASES: list[tuple[str, list[str]]] = [
    ("App 源码", ["OasesChat"]),
    ("App Extensions", ["Extensions"]),
    ("测试", ["OasesChatTests", "OasesChatUITests"]),
    ("vendor（第三方 + iSH）", ["vendor"]),
]

SCALE_BUCKETS_OM: list[tuple[str, list[str]]] = [
    (
        "App 源码",
        [
            "Agent",
            "Views",
            "Providers",
            "Shared",
            "Debug",
            "Diagnostics",
            "FileProvider",
            "WebApp",
            "iSH",
            "NativeOffloads",
            "MinisApp.swift",
            "AppDelegate.swift",
            "MinisApp-Bridging-Header.h",
            "ISHCommandExecutionExample.swift",
        ],
    ),
    ("App Extensions", ["AgentWidget", "ShareExtension"]),
    ("测试", ["MinisTests", "MinisUITests"]),
    ("vendor（第三方 + iSH）", ["Vendor"]),
]

# --------------------------------------------------------------------------- #
# Filesystem helpers
# --------------------------------------------------------------------------- #


def _pruned(path: Path) -> bool:
    """True when any path component is an excluded build/asset directory."""
    for part in path.parts:
        if part in PRUNE_DIRS:
            return True
        if part.endswith(PRUNE_SUFFIXES):
            return True
    return False


def iter_code_files(root: Path, max_depth: int | None = None) -> list[Path]:
    """All code files under `root`, pruning build/asset dirs.

    max_depth=1 restricts to files directly inside `root` (used for the
    "top-level loose files" rows in the module map).
    """
    if not root.exists():
        return []
    if root.is_file():
        return [root] if root.suffix in CODE_EXT else []

    out: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        d = Path(dirpath)
        dirnames[:] = [
            n
            for n in dirnames
            if n not in PRUNE_DIRS and not n.endswith(PRUNE_SUFFIXES)
        ]
        if max_depth is not None:
            depth = len(d.relative_to(root).parts)
            if depth >= max_depth:
                dirnames[:] = []
                if depth > max_depth - 1:
                    continue
        for name in filenames:
            p = d / name
            if p.suffix in CODE_EXT:
                out.append(p)
    return out


def count_lines(path: Path) -> int:
    try:
        with path.open("rb") as fh:
            return sum(1 for _ in fh)
    except OSError:
        return 0


def measure(paths: list[Path]) -> dict[str, int]:
    """Aggregate file counts + line counts, split Swift vs C-family."""
    res = {"files": 0, "swift_files": 0, "swift_lines": 0, "c_files": 0, "c_lines": 0}
    for p in paths:
        n = count_lines(p)
        res["files"] += 1
        if p.suffix in SWIFT_EXT:
            res["swift_files"] += 1
            res["swift_lines"] += n
        else:
            res["c_files"] += 1
            res["c_lines"] += n
    return res


def measure_roots(base: Path, relpaths: list[str], max_depth: int | None = None) -> dict[str, int]:
    files: list[Path] = []
    for rel in relpaths:
        files.extend(iter_code_files(base / rel, max_depth=max_depth))
    return measure(files)


# --------------------------------------------------------------------------- #
# Section 1: two-sided scale
# --------------------------------------------------------------------------- #


def section_scale(om: Path, oa: Path) -> tuple[str, list[str]]:
    warnings: list[str] = []
    lines = [
        "## 1. 两侧规模（实测）",
        "",
        "统计口径：递归收集 `.swift` / `.m` / `.mm` / `.h` / `.c` / `.cpp`；剔除",
        "`build` `.build` `DerivedData` `Pods` `node_modules` `.git` `.shots` `.zcode`",
        "`Preview Content` `default_mount` 以及 `*.xcodeproj` `*.xcassets` `*.lproj` `*.bundle`。",
        "行数是物理行（含空行与注释）。",
        "",
        "| 分桶 | OpenMinis 文件 | OpenMinis Swift 行 | OpenMinis C/ObjC 行 | OasesChat 文件 | OasesChat Swift 行 | OasesChat C/ObjC 行 |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]

    om_totals = {"files": 0, "swift_lines": 0, "c_lines": 0}
    oa_totals = {"files": 0, "swift_lines": 0, "c_lines": 0}

    for (label, om_rel), (_, oa_rel) in zip(SCALE_BUCKETS_OM, SCALE_BUCKETS_OASES):
        a = measure_roots(om, om_rel)
        b = measure_roots(oa, oa_rel)
        for k in om_totals:
            om_totals[k] += a[k]
            oa_totals[k] += b[k]
        lines.append(
            f"| {label} | {a['files']} | {a['swift_lines']:,} | {a['c_lines']:,} "
            f"| {b['files']} | {b['swift_lines']:,} | {b['c_lines']:,} |"
        )

    lines.append(
        f"| **合计** | **{om_totals['files']}** | **{om_totals['swift_lines']:,}** "
        f"| **{om_totals['c_lines']:,}** | **{oa_totals['files']}** "
        f"| **{oa_totals['swift_lines']:,}** | **{oa_totals['c_lines']:,}** |"
    )

    om_app = measure_roots(om, SCALE_BUCKETS_OM[0][1])
    oa_app = measure_roots(oa, SCALE_BUCKETS_OASES[0][1])
    delta_files = oa_app["files"] - om_app["files"]
    delta_swift = oa_app["swift_lines"] - om_app["swift_lines"]
    lines += [
        "",
        f"App 源码桶差值：文件 {delta_files:+d}，Swift 行 {delta_swift:+,}。",
    ]
    if delta_swift > 0:
        lines.append(
            "OasesChat 的 App 源码规模**大于** OpenMinis —— 移植过程中做了目录重组与文件拆分，"
            "并新增了 OasesChat 独有特性（见 2.3），所以“移植完成度”不能用行数比值来推断。"
        )
    else:
        warnings.append(
            f"App 源码桶 Swift 行数少于 OpenMinis（{delta_swift:+,}），可能存在未移植代码，请人工核对。"
        )
    return "\n".join(lines), warnings


# --------------------------------------------------------------------------- #
# Section 2: module landing map
# --------------------------------------------------------------------------- #


def section_modules(om: Path, oa: Path) -> tuple[str, list[str]]:
    warnings: list[str] = []
    lines = [
        "## 2. 模块落点映射（OpenMinis → OasesChat）",
        "",
        "两棵树不同构（OpenMinis 按 `Agent/*` + `Views/*` 分组，OasesChat 按",
        "`Services/*` + `Features/*` 分组），因此落点映射在 `scripts/gen_port_inventory.py`",
        "的 `MODULE_MAP` / `FILE_MAP` 里**显式声明**——映射本身也是可审阅的输出，",
        "而不是脚本猜出来的。文件数为该目录递归代码文件数；标注 `depth=1` 的行只数直属文件。",
        "",
        "| OpenMinis 模块 | 文件 | OasesChat 落点 | 文件 | 状态 | 说明 |",
        "|---|---:|---|---:|:---:|---|",
    ]

    for src_rel, dst_rels, note in MODULE_MAP:
        # A note containing "depth=1" means: compare only the directory's own
        # loose files, because its subdirectories are mapped by their own rows.
        depth = 1 if "depth=1" in note else None
        a = measure_roots(om, [src_rel], max_depth=depth)
        b = measure_roots(oa, dst_rels, max_depth=depth)
        src_exists = (om / src_rel).exists()
        missing = [r for r in dst_rels if not (oa / r).exists()]

        if not src_exists:
            status = "⚠️ 源缺失"
            warnings.append(f"MODULE_MAP 声明的 OpenMinis 路径不存在：`{src_rel}`（映射表已过期）")
        elif not dst_rels:
            status = "⬜ 未移植"
        elif missing:
            status = "⚠️ 落点缺失"
            warnings.append(
                f"`{src_rel}` 的落点目录不存在：{', '.join('`%s`' % m for m in missing)}"
            )
        elif a["files"] == 0 and b["files"] == 0:
            # Resource-only directory on both sides (e.g. Resources/, Configs/):
            # zero code files is the expected state, not a gap.
            status = "➖ 资源目录"
        elif b["files"] == 0:
            status = "⚠️ 落点空"
            warnings.append(f"`{src_rel}` 的落点存在但没有代码文件：{', '.join('`%s`' % r for r in dst_rels)}")
        elif b["files"] >= a["files"]:
            status = "✅"
        else:
            status = "🟡 偏少"

        dst_txt = "<br>".join(f"`{r}`" for r in dst_rels) if dst_rels else "—"
        lines.append(
            f"| `{src_rel}`{' (depth=1)' if depth else ''} | {a['files']} | {dst_txt} | {b['files']} | {status} | {note} |"
        )

    lines += [
        "",
        "### 2.1 根目录单文件映射",
        "",
        "| OpenMinis 文件 | 行 | OasesChat 落点 | 行 | 状态 | 说明 |",
        "|---|---:|---|---:|:---:|---|",
    ]
    for src_rel, dst_rels, note in FILE_MAP:
        sp = om / src_rel
        a_lines = count_lines(sp) if sp.is_file() else 0
        b_lines = 0
        missing = []
        for r in dst_rels:
            p = oa / r
            if p.is_file():
                b_lines += count_lines(p)
            elif p.is_dir():
                b_lines += sum(count_lines(x) for x in iter_code_files(p))
            else:
                missing.append(r)
        if not sp.exists():
            status = "⚠️ 源缺失"
            warnings.append(f"FILE_MAP 声明的 OpenMinis 文件不存在：`{src_rel}`")
        elif not dst_rels:
            status = "🔴 真实缺口" if note.startswith("真实缺口") else "⬜ 未移植"
            if note.startswith("真实缺口"):
                warnings.append(f"真实缺口：`{src_rel}` 在 OasesChat 无任何落点 —— {note}")
        elif missing:
            status = "⚠️ 落点缺失"
            warnings.append(f"`{src_rel}` 的落点不存在：{', '.join('`%s`' % m for m in missing)}")
        elif sp.suffix in CODE_EXT and a_lines and b_lines < a_lines * 0.5:
            # Only meaningful for source files — line count says nothing useful
            # about .plist / .xcstrings / .storyboard / .entitlements payloads.
            status = "🟡 显著瘦身"
            warnings.append(
                f"`{src_rel}` 落点行数只有源的 {b_lines / a_lines:.0%}（{a_lines:,} → {b_lines:,}），"
                "需人工确认是刻意精简还是漏移植。"
            )
        else:
            status = "✅"
        dst_txt = "<br>".join(f"`{r}`" for r in dst_rels) if dst_rels else "—"
        lines.append(f"| `{src_rel}` | {a_lines:,} | {dst_txt} | {b_lines:,} | {status} | {note} |")

    # OpenMinis top-level entries not covered by either map -> report, don't hide.
    mapped = {m.split("/")[0] for m, _, _ in MODULE_MAP} | {f for f, _, _ in FILE_MAP}
    unmapped = []
    for child in sorted(om.iterdir()):
        name = child.name
        if name.startswith(".") or name in mapped:
            continue
        if child.is_dir() and (name.endswith(PRUNE_SUFFIXES) or name in PRUNE_DIRS):
            continue
        n = len(iter_code_files(child)) if child.is_dir() else (1 if child.suffix in CODE_EXT else 0)
        unmapped.append((name, n))
    lines += [
        "",
        "### 2.2 未纳入映射表的 OpenMinis 顶层条目",
        "",
        "（多为资源/工程文件，不含代码则无需映射；**含代码的条目必须补进 `MODULE_MAP`**）",
        "",
    ]
    if unmapped:
        lines += ["| 条目 | 代码文件数 |", "|---|---:|"]
        for name, n in unmapped:
            lines.append(f"| `{name}` | {n} |")
            if n > 0:
                warnings.append(
                    f"OpenMinis 顶层 `{name}` 含 {n} 个代码文件但未出现在 MODULE_MAP/FILE_MAP 中。"
                )
    else:
        lines.append("✅ 无遗漏：所有 OpenMinis 顶层条目都已被 `MODULE_MAP` / `FILE_MAP` 覆盖。")

    # OasesChat feature/service dirs with no OpenMinis source -> new work.
    mapped_dst = set()
    for _, dsts, _ in MODULE_MAP:
        mapped_dst.update(dsts)
    for _, dsts, _ in FILE_MAP:
        mapped_dst.update(dsts)
    extras = []
    for parent in ("OasesChat/Features", "OasesChat/Services"):
        base = oa / parent
        if not base.is_dir():
            continue
        for child in sorted(base.iterdir()):
            if not child.is_dir():
                continue
            rel = f"{parent}/{child.name}"
            if rel in mapped_dst:
                continue
            extras.append((rel, len(iter_code_files(child))))
    if extras:
        lines += [
            "",
            "### 2.3 OasesChat 侧无 OpenMinis 对位的目录（移植期新增/重组）",
            "",
            "| OasesChat 目录 | 代码文件数 |",
            "|---|---:|",
        ]
        for rel, n in extras:
            lines.append(f"| `{rel}` | {n} |")

    return "\n".join(lines), warnings


# --------------------------------------------------------------------------- #
# Section 3: NativeOffload registration audit
# --------------------------------------------------------------------------- #

BOOTSTRAP_REL = "vendor/iSH/offloads/OasesChatOffloadBootstrap.m"
OFFLOAD_DIR_REL = "vendor/iSH/offloads"
REGISTER_RE = re.compile(r"\b([a-z][a-z0-9_]*_offload_register)\s*\(")


def symbol_candidates(stem: str) -> dict[str, str]:
    """Candidate register symbols for an `<X>Offload.m` file, keyed by variant.

    The bootstrap's naming is NOT internally consistent, so a single rule cannot
    cover it:
        HealthKitOffload.m  -> healthkit_offload_register   (acronym kept flat)
        HomeKitOffload.m    -> homekit_offload_register     (flat)
        ModelUseOffload.m   -> model_use_offload_register   (camel split!)
        BrowserUseOffload.m -> browser_use_offload_register  (camel split!)
        FFmpegOffload.m     -> ffmpeg_offload_register      (flat)
    We therefore generate both a flattened and a camel-split candidate and record
    which variant actually matched, so the inconsistency is visible in the report.
    """
    cands: dict[str, str] = {}
    flat = stem.lower()
    cands[f"{flat}_offload_register"] = "flat"

    s = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", stem)
    s = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", "_", s)
    snake = s.lower()
    if f"{snake}_offload_register" not in cands:
        cands[f"{snake}_offload_register"] = "camel-split"
    return cands


def section_offloads(oa: Path) -> tuple[str, list[str]]:
    warnings: list[str] = []
    boot = oa / BOOTSTRAP_REL
    odir = oa / OFFLOAD_DIR_REL

    lines = ["## 3. NativeOffload 注册核对", ""]

    if not boot.is_file():
        warnings.append(f"找不到 bootstrap 文件 `{BOOTSTRAP_REL}`，offload 核对整体跳过。")
        lines.append(f"⚠️ 找不到 `{BOOTSTRAP_REL}`，本节无法生成。")
        return "\n".join(lines), warnings

    text = boot.read_text(encoding="utf-8", errors="replace")

    # Restrict extraction to the bootstrap function body so header prototypes or
    # commented-out lines elsewhere cannot inflate the count.
    body = text
    m = re.search(r"void\s+oases_offload_bootstrap\s*\([^)]*\)\s*\{", text)
    if m:
        depth, i = 0, m.end() - 1
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = text[m.end():i]
    else:
        warnings.append("未能在 bootstrap 里定位 `oases_offload_bootstrap` 函数体，退化为全文件扫描。")

    body_nocomment = re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", body, flags=re.S))
    registered = sorted(set(REGISTER_RE.findall(body_nocomment)))

    all_m = sorted(p.name for p in odir.glob("*.m"))
    offload_m = [n for n in all_m if n.endswith("Offload.m")]
    support_m = [n for n in all_m if n not in offload_m]

    rows: list[tuple[str, str, str, str]] = []
    matched_symbols: set[str] = set()
    unmatched_files: list[str] = []

    for name in offload_m:
        stem = name[: -len("Offload.m")]
        cands = symbol_candidates(stem)
        hit = next((c for c in cands if c in registered), None)
        if hit:
            matched_symbols.add(hit)
            variant = cands[hit]
            rows.append((name, f"`{hit}()`", "✅ 已注册", variant))
        else:
            unmatched_files.append(name)
            rows.append(
                (
                    name,
                    "候选：" + " / ".join(f"`{c}`" for c in cands),
                    "❌ 未注册",
                    "—",
                )
            )

    orphan_symbols = [s for s in registered if s not in matched_symbols]

    lines += [
        f"- `{OFFLOAD_DIR_REL}/*.m` 总数：**{len(all_m)}**"
        f"（其中 `*Offload.m` **{len(offload_m)}** 个 + 支撑文件 {len(support_m)} 个："
        + ", ".join(f"`{n}`" for n in support_m)
        + "）",
        f"- `{BOOTSTRAP_REL}` 中 `oases_offload_bootstrap()` 内提取到的 "
        f"`*_offload_register()` 符号：**{len(registered)}**",
        f"- 匹配结果：**{len(matched_symbols)}/{len(offload_m)}** 个 `*Offload.m` 有对应注册调用",
        "",
        "符号名规范化不是简单小写（`HealthKit`→`healthkit` 扁平化，但 `ModelUse`→`model_use` 驼峰拆分），",
        "所以脚本对每个文件生成扁平 + 驼峰拆分两种候选，并记录实际命中的变体——",
        "命中不了的文件会作为 ❌ 报告出来，不会静默通过。",
        "",
        "| `.m` 文件 | 注册符号 | 状态 | 命名变体 |",
        "|---|---|:---:|---|",
    ]
    for name, sym, status, variant in rows:
        lines.append(f"| `{name}` | {sym} | {status} | {variant} |")

    lines.append("")
    if unmatched_files:
        lines.append(
            "⚠️ **有 `*Offload.m` 找不到注册调用**："
            + ", ".join(f"`{n}`" for n in unmatched_files)
        )
        warnings.append(
            "以下 offload 文件未匹配到 register 符号："
            + ", ".join(unmatched_files)
        )
    if orphan_symbols:
        lines.append(
            "⚠️ **bootstrap 里有注册调用但找不到对应 `.m` 文件**："
            + ", ".join(f"`{s}`" for s in orphan_symbols)
        )
        warnings.append(
            "以下 register 符号没有对应的 *Offload.m：" + ", ".join(orphan_symbols)
        )
    if not unmatched_files and not orphan_symbols:
        lines.append(
            f"✅ 双向闭合：{len(offload_m)} 个 `*Offload.m` ↔ {len(registered)} 个 register 符号，无孤儿。"
        )

    return "\n".join(lines), warnings


# --------------------------------------------------------------------------- #
# Section 4: tests
# --------------------------------------------------------------------------- #

TEST_FUNC_RE = re.compile(r"^\s*(?:@\w+\s+)*(?:public\s+|private\s+|internal\s+)?func\s+(test[A-Za-z0-9_]*)\s*\(", re.M)
SWIFT_TESTING_RE = re.compile(r"^\s*@Test\b", re.M)


def _test_stats(root: Path) -> dict:
    files = [p for p in iter_code_files(root) if p.suffix == ".swift"]
    n_xctest = 0
    n_swift_testing = 0
    per_file = []
    for p in sorted(files):
        try:
            t = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        a = len(TEST_FUNC_RE.findall(t))
        b = len(SWIFT_TESTING_RE.findall(t))
        n_xctest += a
        n_swift_testing += b
        per_file.append((p, a, b))
    return {
        "files": len(files),
        "xctest": n_xctest,
        "swift_testing": n_swift_testing,
        "per_file": per_file,
    }


def section_tests(om: Path, oa: Path) -> tuple[str, list[str]]:
    warnings: list[str] = []
    oa_t = _test_stats(oa / "OasesChatTests")
    om_t = _test_stats(om / "MinisTests")

    lines = [
        "## 4. 测试",
        "",
        "`func test*` 用行首正则统计（XCTest 风格）；`@Test` 单独计数（swift-testing 风格）。",
        "",
        "| 侧 | 测试目录 | Swift 文件 | `func test*` | `@Test` |",
        "|---|---|---:|---:|---:|",
        f"| OpenMinis | `MinisTests` | {om_t['files']} | {om_t['xctest']} | {om_t['swift_testing']} |",
        f"| OasesChat | `OasesChatTests` | {oa_t['files']} | {oa_t['xctest']} | {oa_t['swift_testing']} |",
        "",
        "### 4.1 OasesChatTests 逐文件",
        "",
        "| 文件 | `func test*` | `@Test` |",
        "|---|---:|---:|",
    ]
    for p, a, b in oa_t["per_file"]:
        kind = "" if p.name.endswith("Tests.swift") else "（helper/fixture）"
        lines.append(f"| `{p.relative_to(oa)}`{kind} | {a} | {b} |")
        # Only a *Tests.swift file with zero cases is suspicious; fixtures are fine.
        if a == 0 and b == 0 and p.name.endswith("Tests.swift"):
            warnings.append(f"`*Tests.swift` 却不含任何测试用例：`{p.relative_to(oa)}`（空壳测试）")

    if oa_t["xctest"] + oa_t["swift_testing"] == 0:
        warnings.append("OasesChatTests 里没有识别到任何测试用例——统计正则或测试目录可能有问题。")
    return "\n".join(lines), warnings


# --------------------------------------------------------------------------- #
# Section 5: localization
# --------------------------------------------------------------------------- #


def _xcstrings_stats(path: Path) -> dict | None:
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError) as exc:
        return {"error": str(exc)}
    strings = data.get("strings") or {}
    langs: set[str] = set()
    translated: dict[str, int] = {}
    no_loc = 0
    for _, entry in strings.items():
        locs = entry.get("localizations") or {}
        if not locs:
            no_loc += 1
        for lang in locs:
            langs.add(lang)
            translated[lang] = translated.get(lang, 0) + 1
    return {
        "keys": len(strings),
        "no_loc": no_loc,
        "source": data.get("sourceLanguage"),
        "langs": sorted(langs),
        "translated": translated,
        "bytes": path.stat().st_size,
        "mtime": datetime.datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
    }


def section_localization(om: Path, oa: Path) -> tuple[str, list[str]]:
    warnings: list[str] = []
    oa_x = _xcstrings_stats(oa / "OasesChat/Localization/Localizable.xcstrings")
    om_x = _xcstrings_stats(om / "Localizable.xcstrings")
    om_lproj = sorted(p.name[: -len(".lproj")] for p in om.glob("*.lproj"))
    # Only first-party .lproj matters; vendored sample apps carry their own Base.lproj.
    oa_lproj = sorted(
        p.name[: -len(".lproj")]
        for p in oa.rglob("*.lproj")
        if not {"build", "vendor", ".git"} & set(p.parts)
    )

    lines = ["## 5. 本地化", ""]

    if not oa_x or "error" in oa_x:
        warnings.append("找不到或无法解析 `OasesChat/Localization/Localizable.xcstrings`。")
        lines.append("⚠️ 找不到 / 无法解析 OasesChat 的 `Localizable.xcstrings`。")
        return "\n".join(lines), warnings

    lines += [
        "| 指标 | OpenMinis | OasesChat |",
        "|---|---|---|",
        f"| `Localizable.xcstrings` 大小 | {om_x['bytes']:,} B | {oa_x['bytes']:,} B |",
        f"| 文件 mtime | {om_x['mtime']} | {oa_x['mtime']} |",
        f"| key 总数 | {om_x['keys']:,} | {oa_x['keys']:,} |",
        f"| 无任何 localization 的 key | {om_x['no_loc']:,} | {oa_x['no_loc']:,} |",
        f"| sourceLanguage | `{om_x['source']}` | `{oa_x['source']}` |",
        f"| xcstrings 语言集 | {', '.join('`%s`' % l for l in om_x['langs'])} | {', '.join('`%s`' % l for l in oa_x['langs'])} |",
        f"| 首party `*.lproj` 目录 | {', '.join('`%s`' % l for l in om_lproj) or '—'} | {', '.join('`%s`' % l for l in oa_lproj) or '—'} |",
        "",
    ]

    missing = [l for l in om_x["langs"] if l not in oa_x["langs"]]
    extra = [l for l in oa_x["langs"] if l not in om_x["langs"]]
    if missing:
        lines.append("⚠️ OpenMinis 有、OasesChat 没有的语言：" + ", ".join(f"`{l}`" for l in missing))
        warnings.append("本地化语言缺失：" + ", ".join(missing))
    if extra:
        lines.append("OasesChat 独有语言：" + ", ".join(f"`{l}`" for l in extra))
    if not missing and not extra:
        lines.append("✅ 两侧 xcstrings 声明的语言集一致（8 种）。")

    lines += [
        "",
        "### 5.1 逐语言已翻译 key 数（真实覆盖率）",
        "",
        "分母是各自的 key 总数。**语言集一致 ≠ 翻译完成** —— 这一栏才是真实进度。",
        "",
        "| 语言 | OpenMinis 已翻译 | 覆盖率 | OasesChat 已翻译 | 覆盖率 |",
        "|---|---:|---:|---:|---:|",
    ]
    om_total = om_x["keys"] or 1
    oa_total = oa_x["keys"] or 1
    all_langs = sorted(set(om_x["langs"]) | set(oa_x["langs"]))
    for lang in all_langs:
        a = om_x["translated"].get(lang, 0)
        b = oa_x["translated"].get(lang, 0)
        lines.append(
            f"| `{lang}` | {a:,} | {a / om_total * 100:.1f}% | {b:,} | {b / oa_total * 100:.1f}% |"
        )

    # Coverage of the non-source languages is the honest progress signal.
    oa_non_src = [l for l in oa_x["langs"] if l != oa_x["source"]]
    om_non_src = [l for l in om_x["langs"] if l != om_x["source"]]
    oa_avg = (
        sum(oa_x["translated"].get(l, 0) for l in oa_non_src) / len(oa_non_src) / oa_total * 100
        if oa_non_src
        else 0.0
    )
    om_avg = (
        sum(om_x["translated"].get(l, 0) for l in om_non_src) / len(om_non_src) / om_total * 100
        if om_non_src
        else 0.0
    )
    lines += [
        "",
        f"非源语言平均覆盖率：OpenMinis **{om_avg:.1f}%** vs OasesChat **{oa_avg:.1f}%**。",
    ]
    if oa_avg < om_avg * 0.5:
        lines.append(
            f"🔴 **这是一个真实缺口，不是统计口径问题。** OasesChat 的 `Localizable.xcstrings` "
            f"声明了 {len(oa_x['langs'])} 种语言，但 {oa_x['no_loc']:,}/{oa_x['keys']:,} 个 key "
            f"完全没有任何 localization 条目 —— 相当于只搭好了表结构，翻译内容基本没填。"
            f"OpenMinis 侧同一指标是 {om_x['no_loc']:,}/{om_x['keys']:,}。"
        )
        warnings.append(
            f"本地化真实缺口：OasesChat 非源语言平均覆盖率仅 {oa_avg:.1f}%"
            f"（OpenMinis {om_avg:.1f}%），{oa_x['no_loc']}/{oa_x['keys']} 个 key 无任何翻译条目。"
        )
    lines.append("")
    lines.append(
        f"注：key 总数 {oa_x['keys']:,} vs OpenMinis {om_x['keys']:,} —— OpenMinis 的 xcstrings 是"
        f" {om_x['bytes'] / 1024 / 1024:.1f}MB 全量表（含大量历史 key），OasesChat 是重建的精简表，"
        "所以**只有 key 总数不可比**；上表的逐语言覆盖率才是可比指标。"
    )
    lines.append("")
    lines.append(
        "注意：`Localizable.xcstrings` 会被 Xcode 的字符串抽取自动重写。若上表 mtime 非常接近"
        "本文件生成时间，说明抽取可能正在进行中，请等抽取结束后重跑脚本再据此判断。"
    )
    return "\n".join(lines), warnings


# --------------------------------------------------------------------------- #
# Section 6: optional dependency switches
# --------------------------------------------------------------------------- #

XCCONFIG_REL = "Configuration/OptionalFrameworks.generated.xcconfig"


def section_optional(oa: Path) -> tuple[str, list[str]]:
    warnings: list[str] = []
    lines = ["## 6. 可选依赖开关", ""]
    p = oa / XCCONFIG_REL
    if not p.is_file():
        warnings.append(f"找不到 `{XCCONFIG_REL}`（应由 scripts/configure_optional_frameworks.sh 生成）")
        lines.append(f"⚠️ 找不到 `{XCCONFIG_REL}` —— 跑一次 `scripts/configure_optional_frameworks.sh`。")
        return "\n".join(lines), warnings

    text = p.read_text(encoding="utf-8", errors="replace")
    flags: dict[str, str] = {}
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("//"):
            continue
        if "=" in s:
            k, v = s.split("=", 1)
            flags[k.strip()] = v.strip()

    lines += [
        f"来源：`{XCCONFIG_REL}`（由 `scripts/configure_optional_frameworks.sh` 在每次 xcodebuild 前重生成）",
        "",
        "| 开关 | 值 | 含义 |",
        "|---|:---:|---|",
    ]
    for k, v in sorted(flags.items()):
        if k == "OASES_HAVE_FFMPEG":
            meaning = (
                "FFmpeg.framework **未**链接，`FFmpegOffload.m` 编译成 no-op"
                if v == "0"
                else "FFmpeg.framework 已链接，`FFmpegOffload.m` 走真实实现"
            )
        else:
            meaning = "—"
        lines.append(f"| `{k}` | `{v}` | {meaning} |")

    if flags.get("OASES_HAVE_FFMPEG") == "0":
        lines += [
            "",
            "⚠️ `OASES_HAVE_FFMPEG = 0`：`ffmpeg_offload_register()` 虽然在 bootstrap 里被调用，"
            "但在当前构建下 `FFmpegOffload.m` 内部编译为 no-op —— **“已注册”≠“功能可用”**。",
        ]
        warnings.append("OASES_HAVE_FFMPEG=0，FFmpeg offload 在当前构建下是 no-op。")
    if not flags:
        warnings.append(f"`{XCCONFIG_REL}` 里没解析出任何开关。")
    return "\n".join(lines), warnings


# --------------------------------------------------------------------------- #
# Section 7: real functional gaps -- literal "unsupported"
# --------------------------------------------------------------------------- #

UNSUPPORTED_RE = re.compile(r'"unsupported"')
SCAN_ROOTS = ["OasesChat", "Extensions", "vendor/iSH", "OasesChatTests"]


def _is_comment_line(line: str) -> bool:
    s = line.strip()
    return s.startswith(("//", "*", "/*", "///", "#pragma"))


def section_unsupported(oa: Path) -> tuple[str, list[str]]:
    warnings: list[str] = []
    hits: list[tuple[str, int, str, bool]] = []
    for rel in SCAN_ROOTS:
        for p in iter_code_files(oa / rel):
            try:
                text = p.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for i, line in enumerate(text.splitlines(), 1):
                if UNSUPPORTED_RE.search(line):
                    hits.append(
                        (str(p.relative_to(oa)), i, line.strip()[:140], _is_comment_line(line))
                    )

    code_hits = [h for h in hits if not h[3]]
    comment_hits = [h for h in hits if h[3]]

    lines = [
        "## 7. 真功能缺口：全仓返回 `\"unsupported\"` 的位置",
        "",
        f'扫描范围：{", ".join("`%s`" % r for r in SCAN_ROOTS)}，匹配字面量 `"unsupported"`。',
        "每条命中都区分**代码行**与**注释行**——注释里写着 “currently a structured unsupported stub”",
        "但代码早已实现，是本仓库口径漂移的主要来源，所以必须分开看。",
        "",
        f"- 代码行命中：**{len(code_hits)}**",
        f"- 注释行命中：**{len(comment_hits)}**",
        "",
    ]

    if code_hits:
        lines += [
            "### 7.1 代码行命中",
            "",
            "| 文件 | 行 | 内容 | 判定 |",
            "|---|---:|---|---|",
        ]
        for f, i, txt, _ in sorted(code_hits):
            verdict = "—"
            if "CBManagerStateUnsupported" in txt or "CBManagerState" in txt:
                verdict = "**不是缺口**：CoreBluetooth 状态枚举转字符串"
            lines.append(f"| `{f}` | {i} | `{txt}` | {verdict} |")
        lines.append("")

    if comment_hits:
        lines += [
            "### 7.2 注释行命中（口径漂移高危区）",
            "",
            "| 文件 | 行 | 内容 |",
            "|---|---:|---|",
        ]
        for f, i, txt, _ in sorted(comment_hits):
            lines.append(f"| `{f}` | {i} | `{txt}` |")
        lines.append("")

    real = [h for h in code_hits if "CBManagerState" not in h[2]]
    if not real:
        lines.append(
            "✅ **没有任何代码路径真的返回 `\"unsupported\"`。** 全部命中都是注释，"
            "或是 CoreBluetooth 的状态枚举映射。文档/注释里“XX 仍是 unsupported stub”的说法已过期。"
        )
    else:
        lines.append(
            "⚠️ 存在真实返回 `\"unsupported\"` 的代码路径，见 7.1。"
        )
        warnings.append(
            "真实 unsupported 代码路径：" + ", ".join(f"{f}:{i}" for f, i, _, _ in real)
        )
    return "\n".join(lines), warnings


# --------------------------------------------------------------------------- #
# Section 8: spot checks for previously-misreported claims
# --------------------------------------------------------------------------- #

SPOT_CHECKS: list[tuple[str, str, str]] = [
    # (label, relpath, kind: file|dir|glob)
    ("VoiceActivityDetector", "OasesChat/Services/Providers/VoiceActivityDetector.swift", "file"),
    ("BrowserTabPool", "OasesChat/Services/Browser/BrowserUse/BrowserTabPool.swift", "file"),
    ("BrowserUse 目录", "OasesChat/Services/Browser/BrowserUse", "dir"),
    ("BrowserUseOffloadBridge", "OasesChat/Services/Agent/Offloads/BrowserUseOffloadBridge.swift", "file"),
    ("SessionsOffloadBridge", "OasesChat/Services/Agent/Offloads/SessionsOffloadBridge.swift", "file"),
    ("Agent/MessageList 落点", "OasesChat/Services/Agent/MessageList", "dir"),
    ("RealTimeCutVADLibrary", "vendor/spm/RealTimeCutVADLibrary", "dir"),
    ("silero_vad.onnx", "vendor/spm/RealTimeCutVADLibrary/RealTimeCutVADLibrary/src/Resources/silero_vad.onnx", "file"),
    ("silero_vad_v5.onnx", "vendor/spm/RealTimeCutVADLibrary/RealTimeCutVADLibrary/src/Resources/silero_vad_v5.onnx", "file"),
    ("RealTimeCutVADStub（占位包，仍在树上）", "vendor/spm/RealTimeCutVADStub", "dir"),
]


def section_spotchecks(oa: Path) -> tuple[str, list[str]]:
    warnings: list[str] = []
    lines = [
        "## 8. 历史误报点复核",
        "",
        "以下条目在 `openminis-port-audit.md` / `migration-progress.md` 里曾被标为缺失或 stub。",
        "这一节每次生成都重新落地核对，避免同一个误报再传一轮。",
        "",
        "| 条目 | 路径 | 存在 | 规模 |",
        "|---|---|:---:|---|",
    ]
    for label, rel, kind in SPOT_CHECKS:
        p = oa / rel
        if kind == "file":
            ok = p.is_file()
            size = f"{count_lines(p):,} 行" if ok and p.suffix in CODE_EXT else (f"{p.stat().st_size:,} B" if ok else "—")
        else:
            ok = p.is_dir()
            size = f"{len(iter_code_files(p))} 个代码文件" if ok else "—"
        lines.append(f"| {label} | `{rel}` | {'✅' if ok else '❌'} | {size} |")
        if not ok:
            warnings.append(f"复核条目缺失：`{rel}`（{label}）")
    return "\n".join(lines), warnings


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description="从代码事实生成 OpenMinis → OasesChat 移植实测清单。"
    )
    ap.add_argument(
        "--out",
        default=str(DEFAULT_OUT),
        help=f"输出 Markdown 路径（默认 {DEFAULT_OUT.relative_to(REPO_ROOT)}）",
    )
    ap.add_argument(
        "--openminis",
        default=str(DEFAULT_OPENMINIS),
        help="OpenMinis src/ios 路径（默认按仓库相对位置推断）",
    )
    ap.add_argument(
        "--repo",
        default=str(REPO_ROOT),
        help="OasesChat 仓库根（默认脚本所在仓库）",
    )
    args = ap.parse_args(argv)

    oa = Path(args.repo).resolve()
    om = Path(args.openminis).resolve()
    out = Path(args.out)
    if not out.is_absolute():
        out = (oa / out).resolve()

    if not oa.is_dir():
        print(f"[FATAL] OasesChat 仓库根不存在：{oa}", file=sys.stderr)
        return 2

    om_ok = om.is_dir()
    warnings: list[str] = []
    if not om_ok:
        warnings.append(
            f"OpenMinis 源码目录不存在：{om} —— 所有对比列会显示为 0，请用 --openminis 指定。"
        )
        print(f"[WARN] OpenMinis 目录不存在：{om}", file=sys.stderr)

    now = datetime.datetime.now().astimezone()
    header = [
        "# OasesChat 移植实测清单（自动生成）",
        "",
        "> **⚠️ 自动生成，请勿手工编辑。**",
        "> 运行 `python3 scripts/gen_port_inventory.py` 重新生成。",
        ">",
        f"> 生成时间：`{now.strftime('%Y-%m-%d %H:%M:%S %z')}`",
        f"> OasesChat 仓库：`{oa}`",
        f"> OpenMinis 源码：`{om}`" + ("" if om_ok else "  ← **不存在**"),
        "",
        "本文件是**实测数据的唯一来源**。`docs/openminis-port-audit.md` 与",
        "`docs/migration-progress.md` 是**决策与差异记录**——两者口径冲突时，以本文件为准。",
        "",
        "---",
        "",
    ]

    sections: list[str] = []
    for fn, argsx in (
        (section_scale, (om, oa)),
        (section_modules, (om, oa)),
        (section_offloads, (oa,)),
        (section_tests, (om, oa)),
        (section_localization, (om, oa)),
        (section_optional, (oa,)),
        (section_unsupported, (oa,)),
        (section_spotchecks, (oa,)),
    ):
        try:
            body, warns = fn(*argsx)
        except Exception as exc:  # noqa: BLE001 - a broken section must not kill the run
            body = f"## （本节生成失败）\n\n```\n{type(exc).__name__}: {exc}\n```"
            warns = [f"{fn.__name__} 生成失败：{type(exc).__name__}: {exc}"]
        sections.append(body)
        warnings.extend(warns)

    tail = ["## 9. 生成期告警", ""]
    if warnings:
        tail.append(f"共 **{len(warnings)}** 条。这些是脚本无法确认、需要人工处理的点：")
        tail.append("")
        for w in warnings:
            tail.append(f"- {w}")
    else:
        tail.append("✅ 无告警：所有映射、符号、路径都双向闭合。")
    tail += [
        "",
        "---",
        "",
        f"_由 `scripts/gen_port_inventory.py` 于 {now.strftime('%Y-%m-%d %H:%M:%S %z')} 生成。_",
    ]

    doc = "\n".join(header) + "\n\n".join(sections) + "\n\n" + "\n".join(tail) + "\n"

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(doc, encoding="utf-8")

    print(f"[ok] 已写入 {out}")
    print(f"[ok] {len(doc.splitlines())} 行 / {len(doc):,} 字符")
    if warnings:
        print(f"[warn] {len(warnings)} 条生成期告警：")
        for w in warnings:
            print(f"       - {w}")
    else:
        print("[ok] 无告警")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
