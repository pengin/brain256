#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
SVC="$here/../../profiles/imx28/overlay/etc/init.d/brainwrt-ct"
root=$(mktemp -d)
mkdir -p "$root/apps/on/"  "$root/apps/off/" "$root/apps/evil/"
printf 'exec="/x"\nautostart="1"\n' > "$root/apps/on/manifest.conf"
printf 'exec="/x"\nautostart="0"\n' > "$root/apps/off/manifest.conf"
printf 'autostart="1"\ntouch %s/pwned\n' "$root" > "$root/apps/evil/manifest.conf"
# サービス内の autostart 判定関数を切り出して呼ぶ（BRAINWRT_CT は echo スタブ）。
# ct_autostart_all は `$BRAINWRT_CT up <name>` を呼ぶので、echo なら "up <name>" が出る。
out=$(APPS="$root/apps" BRAINWRT_CT=echo sh -c '. "'"$SVC"'"; ct_autostart_all')
echo "$out" | grep -q "up on"  || { echo "FAIL: on should start"; exit 1; }
echo "$out" | grep -q "up off" && { echo "FAIL: off should not start"; exit 1; }
[ ! -e "$root/pwned" ] || { echo "FAIL: manifest executed shell code"; exit 1; }
echo PASS; rm -rf "$root"
