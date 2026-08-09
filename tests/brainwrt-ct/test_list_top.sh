#!/bin/sh
# list(登録全件を state 付きで表示)と top(CPU%/MEM% を 1 回サンプル)を、
# 偽の $APPS と $CGBASE を組んで検証する。cgroup/overlay 不要でホストで回る。
set -eu
here=$(cd "$(dirname "$0")" && pwd)
CT="$here/../../profiles/imx28/overlay/usr/sbin/brainwrt-ct"
root=$(mktemp -d)
APPS="$root/apps"; CGB="$root/cg/brainwrt-ct"

# 登録: webcam(稼働中・autostart on)/ idle(停止・autostart off)/
#       stale(cgroup はあるが procs 空=クラッシュ後、down 扱いになるべき)
mkdir -p "$APPS/webcam" "$APPS/idle" "$APPS/stale"
printf 'exec="/x"\nautostart="1"\n' > "$APPS/webcam/manifest.conf"
printf 'exec="/x"\nautostart="0"\n' > "$APPS/idle/manifest.conf"
printf 'exec="/x"\nautostart="0"\n' > "$APPS/stale/manifest.conf"
mkdir -p "$CGB/stale"; : > "$CGB/stale/cgroup.procs"   # 空 procs

# webcam だけ cgroup を用意(=稼働中扱い)
mkdir -p "$CGB/webcam"
printf '1411\n1418\n' > "$CGB/webcam/cgroup.procs"
echo 462848    > "$CGB/webcam/memory.current"
echo 33554432  > "$CGB/webcam/memory.max"
echo 843776    > "$CGB/webcam/memory.peak"
printf 'usage_usec 2632056\nnr_periods 187\nnr_throttled 30\n' > "$CGB/webcam/cpu.stat"

env="BRAINWRT_CT_APPS=$APPS BRAINWRT_CT_CGROOT=$root/cg"

fail=0
chk() { echo "$1" | grep -qF -e "$2" || { echo "MISSING in $3: $2"; fail=1; }; }

out=$(env BRAINWRT_CT_APPS="$APPS" BRAINWRT_CT_CGROOT="$root/cg" "$CT" list)
echo "--- list ---"; echo "$out"
chk "$out" "webcam" list
chk "$out" "up"     list
chk "$out" "on"     list
chk "$out" "452.0K/32.0M" list   # 462848B=452.0K, 33554432B=32.0M
chk "$out" "824.0K" list         # 843776B=824.0K peak
chk "$out" "2.6"    list         # 2632056us -> 2.6s
chk "$out" "30/187" list
chk "$out" "idle"   list
chk "$out" "down"   list
chk "$out" "off"    list
# stale は cgroup があるが procs 空 -> down 扱い(has_procs が空を false と判定)
echo "$out" | grep -E '^stale +down' >/dev/null || { echo "stale should be down"; fail=1; }

out=$(env BRAINWRT_CT_APPS="$APPS" BRAINWRT_CT_CGROOT="$root/cg" "$CT" top 1)
echo "--- top ---"; echo "$out"
chk "$out" "CPU%"   top
chk "$out" "webcam" top
# 静的な cpu.stat なので delta=0 -> CPU% 0.0、MEM% は 462848/33554432*100=1.4
chk "$out" "0.0%"   top
chk "$out" "1.4%"   top
# idle は cgroup が無い(=停止)ので top には出ない
echo "$out" | grep -qF "idle" && { echo "idle should NOT appear in top"; fail=1; } || true

[ "$fail" = 0 ] && echo PASS || { echo FAIL; exit 1; }
rm -rf "$root"
