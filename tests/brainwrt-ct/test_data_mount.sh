#!/bin/sh
# brainwrt-data（/data を p3 へマウントする init.d スクリプト）の boot() を単体で
# 検証する。実ブロックデバイスは用意できないため、
# BRAINWRT_DATA_FORCE=1 で通常ファイルを代用する。logger は syslog 行き
#（端末に出ない）なので、mount 呼び出しの検証はスタブがマーカーファイルに
# 記録する方式で行う。
set -eu
here=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$here/../../profiles/imx28/overlay/etc/init.d/brainwrt-data"

fail=0

root=$(mktemp -d)
stub=$(mktemp -d)
export MOUNT_CALLED_FILE="$root/mount-called"
cat > "$stub/mount" << 'EOF'
#!/bin/sh
echo "$*" >> "$MOUNT_CALLED_FILE"
exit 0
EOF
chmod +x "$stub/mount"
PATH="$stub:$PATH"
export PATH

export DATA_MNT="$root/data"
export MOUNTS_FILE="$root/mounts"
mkdir -p "$DATA_MNT"

# --- ケース1: デバイスが存在しない(旧2パーティションイメージ)場合は何もしない ---
export DATA_DEV="$root/nonexistent-dev"
: > "$MOUNTS_FILE"
rm -f "$MOUNT_CALLED_FILE"

rc=0
sh -c ". '$SCRIPT'; boot" || rc=$?
[ "$rc" = 0 ] || { echo "FAIL: case1 exit=$rc"; fail=1; }
[ -f "$MOUNT_CALLED_FILE" ] && { echo "FAIL: mount was called for missing device"; fail=1; }

# --- ケース2: 既にマウント済みなら再マウントしない ---
dev="$root/fake-block-device"
: > "$dev"
export DATA_DEV="$dev"
export BRAINWRT_DATA_FORCE=1
printf 'x %s ext4 rw 0 0\n' "$DATA_MNT" > "$MOUNTS_FILE"
rm -f "$MOUNT_CALLED_FILE"

sh -c ". '$SCRIPT'; boot"
[ -f "$MOUNT_CALLED_FILE" ] && { echo "FAIL: mount was called though already mounted"; fail=1; }

# --- ケース3: デバイスはあるが未マウント -> mount を試みる ---
: > "$MOUNTS_FILE"
rm -f "$MOUNT_CALLED_FILE"

sh -c ". '$SCRIPT'; boot"
[ -f "$MOUNT_CALLED_FILE" ] || { echo "FAIL: mount was not called"; fail=1; }
grep -qF -- "-t ext4 $dev $DATA_MNT" "$MOUNT_CALLED_FILE" 2>/dev/null || {
    echo "FAIL: unexpected mount args: $(cat "$MOUNT_CALLED_FILE" 2>/dev/null)"; fail=1;
}

rm -rf "$root" "$stub"
[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
