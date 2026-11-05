#!/bin/sh
# Runs inside `alpine:3.21` (linux/arm64). Builds a clean rootfs in /rootfs
# with `apk --root` so the container's own build tools never leak into it,
# then writes /out/rootfs.tar, /out/world and /out/alpine-release.
set -eu

MIRROR="${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
BRANCH=v3.21
DEFAULT_MIRROR=https://dl-cdn.alpinelinux.org/alpine

printf '%s/%s/main\n%s/%s/community\n' "$MIRROR" "$BRANCH" "$MIRROR" "$BRANCH" > /etc/apk/repositories
apk add --no-cache tar >/dev/null

packages=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' /build/packages.txt | grep -v '^$' | tr '\n' ' ')

mkdir -p /rootfs/etc/apk
cp -a /etc/apk/keys /rootfs/etc/apk/
cp /etc/apk/repositories /rootfs/etc/apk/repositories
# shellcheck disable=SC2086
apk --root /rootfs --initdb --update-cache --no-cache add $packages

# Byte-compile Python with checked-hash pycs: git and the app bundle do not
# preserve mtimes, so timestamp pycs would all be stale on device and the
# emulated interpreter would recompile on every first import.
pystdlib=$(chroot /rootfs /usr/bin/python3 -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])')
chroot /rootfs /usr/bin/python3 -m compileall -q -j 0 \
    --invalidation-mode checked-hash \
    -x '/(test|tests|idlelib|turtledemo)/' \
    "$pystdlib" >/dev/null

# PEP 668: this is a single-user sandbox; let `pip install` work.
rm -f /rootfs/usr/lib/python3*/EXTERNALLY-MANAGED

# Baseline DNS for the first boot; the app rewrites it from the iOS resolver
# (oases_refresh_dns) as soon as the kernel is up and on network changes.
printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n' > /rootfs/etc/resolv.conf

# Ship the canonical upstream mirror; ogent-need falls back to CN mirrors.
printf '%s/%s/main\n%s/%s/community\n' "$DEFAULT_MIRROR" "$BRANCH" "$DEFAULT_MIRROR" "$BRANCH" > /rootfs/etc/apk/repositories

rm -rf /rootfs/var/cache/apk/* /rootfs/root/.cache /rootfs/tmp/* /rootfs/run/*

cp /rootfs/etc/apk/world /out/world
cp /rootfs/etc/alpine-release /out/alpine-release
chroot /rootfs /sbin/apk info -v 2>/dev/null | sort > /out/installed.txt

tar -C /rootfs --numeric-owner --xattrs-exclude='*' -cpf /out/rootfs.tar .
echo "rootfs built: alpine $(cat /out/alpine-release), $(wc -l < /out/installed.txt) packages"
