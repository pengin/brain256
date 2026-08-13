#!/bin/sh
# scripts/fetch_kernel.sh の検証。ネットワークを使わない。
set -ue

REPO=$(cd "$(dirname "$0")/.." && pwd)
for t in zip unzip; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t がない"; exit 0; }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CACHE="$WORK/cache"; DEST="$WORK/kernel"
mkdir -p "$CACHE/release"

VER=9.9.9-test
SUMS="$WORK/artifacts.sha256"
# 本物と同じ構造(release/ 配下に zImage と DTB)のダミー zip を作る
echo "dummy-kernel" > "$CACHE/release/zImage"
for m in 1 2 3 4 5 6 7; do echo "dummy-dtb-$m" > "$CACHE/release/imx28-pwsh$m.dtb"; done
(cd "$CACHE" && zip -qr "brain256-kernel-${VER}.zip" release)
rm -rf "$CACHE/release"

SHA=$(shasum -a 256 "$CACHE/brain256-kernel-${VER}.zip" 2>/dev/null | awk '{print $1}' \
      || sha256sum "$CACHE/brain256-kernel-${VER}.zip" | awk '{print $1}')
echo "$SHA  brain256-kernel-${VER}.zip" > "$SUMS"

fail() { echo "FAIL: $1"; exit 1; }
run() {
    KERNEL_RELEASE="kernel-${VER}" KERNEL_VERSION="${VER}" \
        KERNEL_CACHE_DIR="$CACHE" KERNEL_DIR="$DEST" ARTIFACTS_SHA256="$SUMS" \
        BRAIN_MODELS="sh3" "$REPO/scripts/fetch_kernel.sh" imx28
}

# 1. sha256 が一致すれば展開される
run >/dev/null || fail "展開が失敗した"
[ -f "$DEST/zImage" ] || fail "zImage が展開されていない"
[ -f "$DEST/imx28-pwsh3.dtb" ] || fail "DTB が展開されていない"
# `[ ... ] && fail` は条件が偽のときリスト全体が非ゼロを返し、set -e でその場で
# 終了してしまう。判定は必ず if で書く。
if [ -d "$DEST/release" ]; then fail "release/ が剥がされていない"; fi

# 2. sha256 が一致しなければ非ゼロで終わる
rm -rf "$DEST"
echo "0000000000000000000000000000000000000000000000000000000000000000  brain256-kernel-${VER}.zip" > "$SUMS"
if run >/dev/null 2>&1; then fail "sha256 不一致なのに成功してしまった"; fi
if [ -f "$DEST/zImage" ]; then fail "検証に失敗したのに展開してしまった"; fi

echo "PASS: test_fetch_kernel.sh"
