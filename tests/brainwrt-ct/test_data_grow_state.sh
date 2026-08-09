#!/bin/sh
# brainwrt-data-grow の boot() 状態機械を検証する。実ブロックデバイス/実sysfs
# は使えないため、DISK_DEV 等の env var seam + PATH スタブ + マーカーファイルで
# 各遷移を確認する。
set -eu
here=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$here/../../profiles/imx28/overlay/etc/init.d/brainwrt-data-grow"

fail=0
# `[ -f ... ] && { ... }` が「呼ばれていない(正常)」場合に false を返すと、
# それを単独の文として呼んだ箇所で `set -e` がスクリプトを打ち切ってしまう
# (「アサーションが通った」のに「コマンドが失敗した」と誤認されるため)。
# 必ず `return 0` で終端し、失敗は `fail` 変数だけで伝える。
check_absent() { [ -f "$1" ] && { echo "FAIL: $2 was called but should not have been"; fail=1; }; return 0; }
check_present() { [ -f "$1" ] || { echo "FAIL: $2 was not called but should have been"; fail=1; }; return 0; }

root=$(mktemp -d)
stub=$(mktemp -d)

export REBOOT_CALLED_FILE="$root/reboot-called"
cat > "$stub/reboot" << 'EOF'
#!/bin/sh
echo "$*" >> "$REBOOT_CALLED_FILE"
EOF
export RESIZE2FS_CALLED_FILE="$root/resize2fs-called"
export RESIZE2FS_EXIT="${RESIZE2FS_EXIT:-0}"
cat > "$stub/resize2fs" << 'EOF'
#!/bin/sh
echo "$*" >> "$RESIZE2FS_CALLED_FILE"
exit "${RESIZE2FS_EXIT:-0}"
EOF
export OPKG_CALLED_FILE="$root/opkg-called"
export OPKG_INSTALLS_RESIZE2FS="${OPKG_INSTALLS_RESIZE2FS:-0}"
# opkg スタブは「インストール成功」を模擬する際、resize2fs スタブを
# その場で(printf で)新規に書き出す。バックアップファイルからの復元に
# 頼らないことで、「未導入状態」を rm だけで単純に再現できるようにする。
cat > "$stub/opkg" << 'EOF'
#!/bin/sh
echo "$*" >> "$OPKG_CALLED_FILE"
if [ "$OPKG_INSTALLS_RESIZE2FS" = 1 ]; then
    printf '#!/bin/sh\necho "$*" >> "$RESIZE2FS_CALLED_FILE"\nexit "${RESIZE2FS_EXIT:-0}"\n' > "$STUB_DIR/resize2fs"
    chmod +x "$STUB_DIR/resize2fs"
    exit 0
fi
exit 1
EOF
chmod +x "$stub/reboot" "$stub/resize2fs" "$stub/opkg"
export STUB_DIR="$stub"
PATH="$stub:$PATH"
export PATH
export REBOOT_DELAY=0

export DISK_DEV="$root/fake-disk"
export P3_DEV="$root/fake-p3"
export DISK_SIZE_FILE="$root/disk-size"
export P3_SIZE_FILE="$root/p3-size"
export P3_START_FILE="$root/p3-start"
export STATE_FILE="$root/state"
export LOG_FILE="$root/log"

reset_common() {
    rm -f "$REBOOT_CALLED_FILE" "$RESIZE2FS_CALLED_FILE" "$OPKG_CALLED_FILE" "$STATE_FILE"
    dd if=/dev/zero bs=1 count=512 2>/dev/null | LC_ALL=C tr '\0' '\252' > "$DISK_DEV"
    echo 100000 > "$DISK_SIZE_FILE"
    echo 1000 > "$P3_START_FILE"
}

echo "--- case1: p3が存在しない(旧イメージ)-> 何もせず done ---"
reset_common
rm -f "$P3_DEV"
echo 99000 > "$P3_SIZE_FILE"
sh -c ". '$SCRIPT'; boot"
[ "$(cat "$STATE_FILE")" = "done" ] || { echo "FAIL: expected done"; fail=1; }
check_absent "$REBOOT_CALLED_FILE" reboot
check_absent "$RESIZE2FS_CALLED_FILE" resize2fs

echo "--- case2: 未着手、既にジャストサイズ -> パッチせず done ---"
reset_common
: > "$P3_DEV"
export BRAINWRT_DATA_FORCE=1
echo 99000 > "$P3_SIZE_FILE"   # target = 100000-1000 = 99000 と一致
sh -c ". '$SCRIPT'; boot"
[ "$(cat "$STATE_FILE")" = "done" ] || { echo "FAIL: expected done"; fail=1; }
check_absent "$REBOOT_CALLED_FILE" reboot

echo "--- case3: 未着手、拡張必要 -> MBRパッチ + reboot、state=patched ---"
reset_common
: > "$P3_DEV"
echo 50000 > "$P3_SIZE_FILE"   # target(99000) > cur(50000)
sh -c ". '$SCRIPT'; boot"
sleep 0.3
[ "$(cat "$STATE_FILE")" = "patched" ] || { echo "FAIL: expected patched, got $(cat "$STATE_FILE")"; fail=1; }
check_present "$REBOOT_CALLED_FILE" reboot
# 99000 = 0x000182B8 -> LE: b8 82 01 00(cmp でバイト単位に比較、od の
# フォーマット差異を避ける。理由は test_data_grow_mbr.sh のコメント参照)
printf '\270\202\001\000' > "$root/expected-mbr"
dd if="$DISK_DEV" bs=1 skip=490 count=4 2>/dev/null > "$root/got-mbr"
cmp -s "$root/expected-mbr" "$root/got-mbr" || { echo "FAIL: MBR not patched correctly"; fail=1; }

echo "--- case4: patched、カーネルが新サイズ認識、resize2fs既存 -> done ---"
reset_common
echo patched > "$STATE_FILE"
: > "$P3_DEV"
echo 99000 > "$P3_SIZE_FILE"   # cur(99000) >= target(99000)
sh -c ". '$SCRIPT'; boot"
[ "$(cat "$STATE_FILE")" = "done" ] || { echo "FAIL: expected done, got $(cat "$STATE_FILE")"; fail=1; }
check_present "$RESIZE2FS_CALLED_FILE" resize2fs
grep -qF -- "$P3_DEV" "$RESIZE2FS_CALLED_FILE" || { echo "FAIL: resize2fs called with wrong args"; fail=1; }

echo "--- case5: patched、カーネル未認識 -> failed、resize2fs呼ばれない ---"
reset_common
echo patched > "$STATE_FILE"
: > "$P3_DEV"
echo 50000 > "$P3_SIZE_FILE"   # cur(50000) < target(99000)
sh -c ". '$SCRIPT'; boot"
[ "$(cat "$STATE_FILE")" = "failed" ] || { echo "FAIL: expected failed, got $(cat "$STATE_FILE")"; fail=1; }
check_absent "$RESIZE2FS_CALLED_FILE" resize2fs

echo "--- case6: patched、resize2fs未導入、opkg installで導入成功 -> done ---"
reset_common
rm -f "$stub/resize2fs"
echo patched > "$STATE_FILE"
: > "$P3_DEV"
echo 99000 > "$P3_SIZE_FILE"
export OPKG_INSTALLS_RESIZE2FS=1
sh -c ". '$SCRIPT'; boot"
[ "$(cat "$STATE_FILE")" = "done" ] || { echo "FAIL: expected done, got $(cat "$STATE_FILE")"; fail=1; }
check_present "$OPKG_CALLED_FILE" opkg
check_present "$RESIZE2FS_CALLED_FILE" resize2fs
export OPKG_INSTALLS_RESIZE2FS=0

echo "--- case7: patched、opkg install失敗 -> failed、resize2fs呼ばれない ---"
reset_common
rm -f "$stub/resize2fs"
echo patched > "$STATE_FILE"
: > "$P3_DEV"
echo 99000 > "$P3_SIZE_FILE"
sh -c ". '$SCRIPT'; boot"
[ "$(cat "$STATE_FILE")" = "failed" ] || { echo "FAIL: expected failed, got $(cat "$STATE_FILE")"; fail=1; }
check_present "$OPKG_CALLED_FILE" opkg
check_absent "$RESIZE2FS_CALLED_FILE" resize2fs

echo "--- case8: done状態 -> 何もしない ---"
reset_common
echo done > "$STATE_FILE"
: > "$P3_DEV"
echo 50000 > "$P3_SIZE_FILE"
sh -c ". '$SCRIPT'; boot"
[ "$(cat "$STATE_FILE")" = "done" ] || { echo "FAIL: state changed from done"; fail=1; }
check_absent "$REBOOT_CALLED_FILE" reboot
check_absent "$RESIZE2FS_CALLED_FILE" resize2fs

echo "--- case9: failed状態 -> 何もしない(リトライしない) ---"
reset_common
echo failed > "$STATE_FILE"
: > "$P3_DEV"
echo 50000 > "$P3_SIZE_FILE"
sh -c ". '$SCRIPT'; boot"
[ "$(cat "$STATE_FILE")" = "failed" ] || { echo "FAIL: state changed from failed"; fail=1; }
check_absent "$REBOOT_CALLED_FILE" reboot
check_absent "$RESIZE2FS_CALLED_FILE" resize2fs

rm -rf "$root" "$stub"
[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
