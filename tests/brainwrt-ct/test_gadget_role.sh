#!/bin/sh
# brainwrt-gadget が起動時に usb role を device にすることの検証。
# usb-role-switch を持つ DT では ci_hdrc が起動時に role を none にして待つ。
# none のままだとポートがデバイスとして動かず、ホスト PC は Brain を認識しない。
set -eu
here=$(cd "$(dirname "$0")" && pwd)
SVC="$here/../../profiles/imx28/overlay/etc/init.d/brainwrt-gadget"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# 1. role スイッチがあれば device を書き込む
mkdir -p "$root/usb_role/ci_hdrc.0"
echo none > "$root/usb_role/ci_hdrc.0/role"
USB_ROLE_DIR="$root/usb_role" sh -c '. "'"$SVC"'"; gadget_set_role' >/dev/null 2>&1 \
    || fail "gadget_set_role が失敗した"
got=$(cat "$root/usb_role/ci_hdrc.0/role")
[ "$got" = "device" ] || fail "role が device でなく '$got' のまま"

# 2. role スイッチが無い環境でも成功で終わる（旧カーネルや a7200/a7400 では
#    /sys/class/usb_role が空になる。そこで boot が止まると gadget も作られない）
mkdir -p "$root/empty"
USB_ROLE_DIR="$root/empty" sh -c '. "'"$SVC"'"; gadget_set_role' >/dev/null 2>&1 \
    || fail "role スイッチが無いのに非ゼロで終わった"

echo "PASS: test_gadget_role.sh"
