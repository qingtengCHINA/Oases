#!/usr/bin/env python3
"""Convert a rootfs tarball into an iSH fakefs directory (data/ + meta.db).

Byte-for-byte the same on-disk format as iSH's `tools/fakefs.c`
(`fakefs_import`), which is what the embedded runtime mounts:

* ``meta(id, db_inode)`` with one row ``db_inode = 0``. The runtime compares
  it with the real inode of meta.db on first mount and runs
  ``fakefs_rebuild`` (re-keys every row by the host inode, re-creates
  hardlinks), which is exactly what a copied bundle needs.
* ``stats(inode INTEGER PRIMARY KEY, stat BLOB)``; the blob is
  ``struct ish_stat { u32 mode, uid, gid, rdev }`` in little endian with the
  file-type bits included in ``mode``.
* ``paths(path BLOB PRIMARY KEY, inode)``; paths are normalized
  ``/a/b`` byte strings and the root is the empty string.
* Symlinks are stored as regular host files whose content is the link target
  (the app bundle must not contain real symlinks).
* Hardlinks are host hardlinks sharing the target's inode row.
* ``user_version = 3`` and WAL journal mode.

Extra safety for shipping the tree through git and the Xcode bundle:
paths that collide case-insensitively (macOS checkouts) are rejected, as are
names git would treat specially (``.git``, ``.gitignore``, ``.gitattributes``).
"""

from __future__ import annotations

import argparse
import os
import sqlite3
import stat as st
import struct
import sys
import tarfile

SCHEMA = """
create table meta (id integer unique default 0, db_inode integer);
insert into meta (db_inode) values (0);
create table stats (inode integer primary key, stat blob);
create table paths (path blob primary key, inode integer references stats(inode));
create index inode_to_path on paths (inode, path);
"""

GIT_SPECIAL = {".git", ".gitignore", ".gitattributes", ".gitmodules"}


def normalize(name: str) -> str | None:
    """Mirror fakefs.c path_normalize: '/'-joined components, no '..'."""
    parts = []
    for comp in name.split("/"):
        if comp in ("", "."):
            continue
        if comp == "..":
            return None
        parts.append(comp)
    return "".join("/" + p for p in parts)


def type_bits(member: tarfile.TarInfo) -> int:
    if member.isdir():
        return st.S_IFDIR
    if member.issym():
        return st.S_IFLNK
    if member.ischr():
        return st.S_IFCHR
    if member.isblk():
        return st.S_IFBLK
    if member.isfifo():
        return st.S_IFIFO
    return st.S_IFREG


def pack_stat(mode: int, uid: int, gid: int, rdev: int = 0) -> bytes:
    return struct.pack("<IIII", mode & 0xFFFFFFFF, uid, gid, rdev)


def convert(tar_path: str, out_dir: str) -> dict:
    if os.path.exists(out_dir):
        sys.exit(f"refusing to overwrite existing {out_dir}")
    data_dir = os.path.join(out_dir, "data")
    os.makedirs(data_dir)

    db = sqlite3.connect(os.path.join(out_dir, "meta.db"), isolation_level=None)
    db.execute("pragma journal_mode=wal")
    db.execute("begin")
    for statement in filter(None, (s.strip() for s in SCHEMA.split(";"))):
        db.execute(statement)
    db.execute("pragma user_version=3")

    seen_lower: dict[str, str] = {}
    counts = {"dirs": 0, "files": 0, "symlinks": 0, "hardlinks": 0, "special": 0, "bytes": 0}
    has_root = False

    def host(path: str) -> str:
        return os.path.join(data_dir, path.lstrip("/")) if path else data_dir

    def claim(path: str) -> None:
        key = path.lower()
        other = seen_lower.get(key)
        if other is not None and other != path:
            sys.exit(f"case-insensitive path collision: {other!r} vs {path!r}")
        seen_lower[key] = path
        leaf = path.rsplit("/", 1)[-1]
        if leaf in GIT_SPECIAL:
            sys.exit(f"rootfs contains a git-special name: {path!r}")

    def insert_path(path: str, inode: int) -> None:
        db.execute("insert or replace into paths values (?, ?)", (path.encode(), inode))

    with tarfile.open(tar_path, "r:*") as tar:
        for member in tar:
            path = normalize(member.name)
            if path is None:
                print(f"warning: skipped path traversal {member.name!r}", file=sys.stderr)
                continue
            if path == "":
                has_root = True
            else:
                claim(path)

            if member.islnk():
                target = normalize(member.linkname)
                if target is None:
                    sys.exit(f"hardlink escapes root: {member.name!r} -> {member.linkname!r}")
                os.link(host(target), host(path))
                db.execute(
                    "insert or replace into paths values (?, (select inode from paths where path = ? limit 1))",
                    (path.encode(), target.encode()),
                )
                counts["hardlinks"] += 1
                continue

            parent = os.path.dirname(host(path))
            if path:
                os.makedirs(parent, exist_ok=True)

            if member.isdir():
                os.makedirs(host(path), exist_ok=True)
                counts["dirs"] += 1
            elif member.isfile():
                src = tar.extractfile(member)
                with open(host(path), "wb") as out:
                    while chunk := src.read(1 << 20):
                        out.write(chunk)
                counts["files"] += 1
                counts["bytes"] += member.size
            elif member.issym():
                with open(host(path), "wb") as out:
                    out.write(member.linkname.encode())
                counts["symlinks"] += 1
            else:
                # Device nodes / FIFOs: an empty placeholder, metadata lives in meta.db.
                open(host(path), "wb").close()
                counts["special"] += 1

            rdev = 0
            if member.ischr() or member.isblk():
                rdev = (member.devmajor << 8) | member.devminor
            mode = type_bits(member) | (member.mode & 0o7777)
            cur = db.execute("insert into stats (stat) values (?)", (pack_stat(mode, member.uid, member.gid, rdev),))
            insert_path(path, cur.lastrowid)

    if not has_root:
        cur = db.execute("insert into stats (stat) values (?)", (pack_stat(st.S_IFDIR | 0o755, 0, 0),))
        insert_path("", cur.lastrowid)

    db.execute("commit")
    # Closing the last WAL connection checkpoints and drops -wal/-shm, so the
    # bundle ships a single self-contained meta.db.
    db.execute("pragma wal_checkpoint(TRUNCATE)")
    db.close()
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tar")
    parser.add_argument("out_dir")
    args = parser.parse_args()
    counts = convert(args.tar, args.out_dir)
    print(" ".join(f"{k}={v}" for k, v in counts.items()))


if __name__ == "__main__":
    main()
