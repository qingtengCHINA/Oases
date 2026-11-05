#!/bin/sh
# Rebuild the bundled Ogent rootfs (OasesChat/Resources/AlpineFakefs).
#
#   scripts/rootfs/build_alpine_fakefs.sh            # dl-cdn
#   ALPINE_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine scripts/rootfs/build_alpine_fakefs.sh
#
# Needs Docker (linux/arm64) and python3. The previous tree is moved to
# ~/.Trash rather than deleted. Bump ROOTFS_VERSION whenever the package set
# or rootfs layout changes: installed apps compare it with their staged rootfs
# and migrate user data (/root, /home, /usr/local, /opt, /var/oases) forward.
set -eu

ROOTFS_VERSION=2
IMAGE="${ALPINE_IMAGE:-alpine:3.21}"
MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"

HERE=$(cd "$(dirname "$0")" && pwd)
IOS=$(cd "$HERE/../.." && pwd)
DEST="${ROOTFS_DEST:-$IOS/OasesChat/Resources/AlpineFakefs}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ogent-rootfs.XXXXXX")
echo "work dir: $WORK"

docker run --rm --platform linux/arm64 \
    -e MIRROR="$MIRROR" \
    -v "$HERE:/build:ro" -v "$WORK:/out" \
    "$IMAGE" /bin/sh /build/inside_container.sh

python3 "$HERE/tar_to_fakefs.py" "$WORK/rootfs.tar" "$WORK/AlpineFakefs"

python3 - "$WORK" "$ROOTFS_VERSION" <<'EOF'
import hashlib, json, os, sys
work, version = sys.argv[1], int(sys.argv[2])
root = os.path.join(work, "AlpineFakefs")
def sha(rel):
    h = hashlib.sha256()
    with open(os.path.join(root, rel), "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
checked = ["meta.db", "data/bin/sh", "data/sbin/init", "data/etc/alpine-release",
           "data/usr/bin/curl", "data/usr/bin/ffmpeg", "data/usr/bin/yt-dlp", "data/usr/bin/uv"]
world = [l.strip() for l in open(os.path.join(work, "world")) if l.strip()]
manifest = {
    "schemaVersion": 1,
    "rootfsVersion": version,
    "alpineVersion": open(os.path.join(work, "alpine-release")).read().strip(),
    "architecture": "aarch64",
    "packages": world,
    "files": {rel: sha(rel) for rel in checked},
    "runtimeOverlayVersion": 1,
}
with open(os.path.join(root, "rootfs-manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"manifest: rootfsVersion={version} alpine={manifest['alpineVersion']} world={len(world)}")
EOF

cp "$WORK/installed.txt" "$HERE/installed-packages.lock"

if [ -e "$DEST" ]; then
    trash="$HOME/.Trash/AlpineFakefs-$(date +%Y%m%d-%H%M%S)"
    mv "$DEST" "$trash"
    echo "previous rootfs moved to $trash"
fi
mv "$WORK/AlpineFakefs" "$DEST"
du -sh "$DEST"
echo "done: $DEST (tarball kept in $WORK)"
