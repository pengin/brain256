#!/bin/sh
# brainwrt-ct down が、cgroup を落とした後に brainwrt-kdreset（KD_TEXT への
# コンソールリセット）を必ず呼ぶことを検証する。cgroup.kill が「有る」場合／
#「無い」場合の両方、および kdreset 自体が失敗しても down 自体は成功することを、
# KDRESET をスタブして確認する。実 /dev/tty0 は使わない。
set -eu
here=$(cd "$(dirname "$0")" && pwd)
CT="$here/../../profiles/imx28/overlay/usr/sbin/brainwrt-ct"
root=$(mktemp -d)
APPS="$root/apps"; mkdir -p "$APPS"
CGROOT="$root/cg"
stub=$(mktemp -d)

fail=0
must() { "$@" || { echo "FAILED: $*"; fail=1; }; }

# ダウン対象の登録済みバンドルを 1 つ用意する（up はしない。down はプロセスが
# なくても cgroup ディレクトリの掃除 + kdreset 呼び出しをそのまま行う）。
src="$root/src"; mkdir -p "$src/root/usr/bin"
printf 'exec="/usr/bin/foo"\nautostart="0"\n' > "$src/manifest.conf"
echo '#!/bin/sh' > "$src/root/usr/bin/foo"
chmod +x "$src/root/usr/bin/foo"

ct() { env BRAINWRT_CT_APPS="$APPS" BRAINWRT_CT_CGROOT="$CGROOT" BRAINWRT_CT_KDRESET="$KDRESET_NAME" "$CT" "$@"; }

export KDRESET_CALLS_FILE="$root/kdreset-calls"
export KDRESET_EXIT=0
KDRESET_NAME="$stub/fake-kdreset"
cat > "$KDRESET_NAME" << 'EOF'
#!/bin/sh
echo "called" >> "$KDRESET_CALLS_FILE"
exit "$KDRESET_EXIT"
EOF
chmod +x "$KDRESET_NAME"

echo "--- down (no cgroup at all -- neither cgroup.kill nor cgroup.procs) calls kdreset ---"
must ct install foo "$src"
: > "$KDRESET_CALLS_FILE"
must ct down foo
[ "$(wc -l < "$KDRESET_CALLS_FILE" | tr -d "[:space:]")" = 1 ] || { echo "kdreset not called exactly once (no cgroup case)"; fail=1; }

echo "--- down (cgroup.kill present) calls kdreset ---"
cg="$CGROOT/brainwrt-ct/foo"; mkdir -p "$cg"
: > "$cg/cgroup.kill"
: > "$KDRESET_CALLS_FILE"
must ct down foo
[ "$(wc -l < "$KDRESET_CALLS_FILE" | tr -d "[:space:]")" = 1 ] || { echo "kdreset not called exactly once (cgroup.kill case)"; fail=1; }
rm -rf "$cg"

echo "--- down (cgroup.procs present, no cgroup.kill) calls kdreset ---"
mkdir -p "$cg"
: > "$cg/cgroup.procs"
: > "$KDRESET_CALLS_FILE"
must ct down foo
[ "$(wc -l < "$KDRESET_CALLS_FILE" | tr -d "[:space:]")" = 1 ] || { echo "kdreset not called exactly once (cgroup.procs case)"; fail=1; }

echo "--- down succeeds even if kdreset itself fails ---"
export KDRESET_EXIT=1
: > "$KDRESET_CALLS_FILE"
must ct down foo
[ "$(wc -l < "$KDRESET_CALLS_FILE" | tr -d "[:space:]")" = 1 ] || { echo "kdreset not called when it's about to fail"; fail=1; }

echo "--- down succeeds even if kdreset binary is entirely missing ---"
export KDRESET_EXIT=0
KDRESET_NAME="$stub/does-not-exist"
must ct down foo

[ "$fail" = 0 ] && echo PASS || { echo FAIL; exit 1; }
rm -rf "$root" "$stub"
