#!/bin/sh
# dry-run seam を使い、up が正しい overlay / cgroup / ujail コマンドを組むか検証する。
set -eu
here=$(cd "$(dirname "$0")" && pwd)
CT="$here/../../profiles/imx28/overlay/usr/sbin/brainwrt-ct"
root=$(mktemp -d)
mkdir -p "$root/data/apps/webcam/root" "$root/data/apps/webcam/work" "$root/data/apps/webcam/merged"
cp "$here/fixtures/webcam/manifest.conf" "$root/data/apps/webcam/manifest.conf"

out=$(BRAINWRT_CT_DRYRUN=1 BRAINWRT_CT_APPS="$root/data/apps" \
      BRAINWRT_CT_CGROOT="$root/sys/fs/cgroup" "$CT" up webcam)

fail=0
check() { echo "$out" | grep -qF -e "$1" || { echo "MISSING: $1"; fail=1; }; }
check "mount -t overlay overlay -o lowerdir=/,upperdir=$root/data/apps/webcam/root,workdir=$root/data/apps/webcam/work $root/data/apps/webcam/merged"
check "memory.max <- 33554432"
check "cpu.max <- 50000 100000"
check "ujail"
check "-R $root/data/apps/webcam/merged"
check "-w /dev/video0"
check "/usr/bin/webcam-run"
[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
rm -rf "$root"
