#!/bin/sh
# scripts/fetch_boot.sh の検証。ネットワークを使わない。
set -ue

REPO=$(cd "$(dirname "$0")/.." && pwd)
for t in zip unzip gzip; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t がない"; exit 0; }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CACHE="$WORK/cache"; DEST="$WORK/boot"; SUMS="$WORK/artifacts.sha256"
mkdir -p "$CACHE"

REL=test-release
LILO_VER=9.9.9

sha() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }

# uboot zip (release/ を挟む)
mkdir -p "$WORK/u/release"
echo "uboot-loader-sh3" > "$WORK/u/release/gen3_3.bin"
echo "uboot-nk-sh3"     > "$WORK/u/release/edsa3exe.bin"
echo "raw-uboot"        > "$WORK/u/release/u-boot.bin"
(cd "$WORK/u" && zip -qr "$CACHE/uboot-sh3-${REL}.zip" release)

# brainlilo zip (BrainLILO/ を挟む。AppMain.exe の実体は BrainLILO.exe)
mkdir -p "$WORK/l/BrainLILO"
echo "dll1" > "$WORK/l/BrainLILO/BrainLILO.dll"
echo "dll2" > "$WORK/l/BrainLILO/BrainLILODrv.dll"
echo "THIS-IS-BRAINLILO-EXE" > "$WORK/l/BrainLILO/AppMain.exe"
(cd "$WORK/l" && zip -qr "$CACHE/brainlilo-${LILO_VER}.zip" BrainLILO)

# exeopener
printf 'THIS-IS-EXEOPENER\n' > "$WORK/exeopener.exe"
gzip -c "$WORK/exeopener.exe" > "$CACHE/exeopener.exe.gz"

cat > "$SUMS" <<EOF
$(sha "$CACHE/uboot-sh3-${REL}.zip")  uboot-sh3-${REL}.zip
$(sha "$CACHE/brainlilo-${LILO_VER}.zip")  brainlilo-${LILO_VER}.zip
$(sha "$CACHE/exeopener.exe.gz")  exeopener.exe.gz
EOF

fail() { echo "FAIL: $1"; exit 1; }
run() {
    BUILDBRAIN_RELEASE="$REL" BRAINLILO_VERSION="$LILO_VER" \
        BOOT_CACHE_DIR="$CACHE" BOOT_DIR="$DEST" ARTIFACTS_SHA256="$SUMS" \
        BRAIN_MODELS="$1" "$REPO/scripts/fetch_boot.sh" imx28
}

# 1. 正しく配置される
run sh3 >/dev/null || fail "配置が失敗した"
[ -f "$DEST/loader/gen3_3.bin" ] || fail "loader/gen3_3.bin が無い"
[ -f "$DEST/nk/edsa3exe.bin" ]   || fail "nk/edsa3exe.bin が無い"
[ -f "$DEST/lilo/BrainLILO.dll" ] || fail "lilo/BrainLILO.dll が無い"
[ -f "$DEST/lilo/BrainLILODrv.dll" ] || fail "lilo/BrainLILODrv.dll が無い"
# u-boot.bin は p1 に置かないので持ち込まない
if [ -f "$DEST/nk/u-boot.bin" ] || [ -f "$DEST/loader/u-boot.bin" ]; then
    fail "u-boot.bin を持ち込んでいる"
fi

# 2. AppMain.exe と AppMain_.exe が入れ替わっていない
grep -q "THIS-IS-BRAINLILO-EXE" "$DEST/lilo/AppMain_.exe" \
    || fail "AppMain_.exe が BrainLILO.exe になっていない"
grep -q "THIS-IS-EXEOPENER" "$DEST/lilo/AppMain.exe" \
    || fail "AppMain.exe が exeopener になっていない"

# 3. ハッシュ不一致は非ゼロで終わる
rm -rf "$DEST"
sed -i.bak 's/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' "$SUMS"
if run sh3 >/dev/null 2>&1; then fail "ハッシュ不一致なのに成功した"; fi
mv "$SUMS.bak" "$SUMS"

# 4. 非対応モデルは非ゼロで終わる
rm -rf "$DEST"
if run "sh3 a7200" >/dev/null 2>&1; then fail "a7200 を指定したのに成功した"; fi

echo "PASS: test_fetch_boot.sh"
