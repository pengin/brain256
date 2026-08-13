#!/bin/sh
# brainwrt-data-grow が既定で無効であることの検証。
#
# このサービスは p3 を実カード容量まで広げるために MBR を書き換え、カーネルに
# 新しいサイズを読ませるため自分で reboot する。初回起動の途中で何の前触れも
# なく再起動するので、知らずに使うと故障を疑ってしまう。既定では動かさず、
# 使う人が明示的に enable したときだけ動かす。
#
#   /etc/init.d/brainwrt-data-grow enable && reboot
#
# OpenWrt では /etc/rc.d/S<START><名前> のシンボリックリンクがあるサービスを
# 起動時に実行する。overlay にそのリンクを置かないことが「既定で無効」である。
set -ue

REPO=$(cd "$(dirname "$0")/.." && pwd)
RCD="$REPO/profiles/imx28/overlay/etc/rc.d"
INITD="$REPO/profiles/imx28/overlay/etc/init.d"

fail() { echo "FAIL: $1"; exit 1; }

# 1. 本体は同梱する。無効なのは自動起動だけで、enable すれば使える。
[ -f "$INITD/brainwrt-data-grow" ] \
    || fail "brainwrt-data-grow 本体が overlay にない"

# 2. 自動起動のリンクは無い
found=$(ls "$RCD" 2>/dev/null | grep 'brainwrt-data-grow$' || true)
[ -z "$found" ] \
    || fail "brainwrt-data-grow が既定で有効になっている ($found)"

# 3. 他のサービスは有効なままである（rc.d ごと消していないことの確認）
for s in brainwrt-data brainwrt-gadget; do
    ls "$RCD" 2>/dev/null | grep -q "${s}\$" \
        || fail "${s} の自動起動リンクが消えている"
done

# 4. 出来上がった rootfs でも無効である。
#    overlay から消すだけでは足りない。OpenWrt の ImageBuilder は rootfs を
#    仕上げるときに /etc/init.d/ 配下の rc.common スクリプトをすべて enable する
#    ため、放っておくと自動起動リンクが復活する（実際に復活した）。overlay では
#    なく最終成果物を見る。
TAR="$REPO/output/rootfs-imx28.tar"
if [ ! -f "$TAR" ]; then
    echo "PASS: test_data_grow_disabled.sh (rootfs tar が無いので 4 は SKIP)"
    exit 0
fi
list=$(tar -tf "$TAR" | grep 'brainwrt-data-grow' || true)
echo "$list" | grep -q 'etc/init.d/brainwrt-data-grow$' \
    || fail "rootfs に brainwrt-data-grow 本体が入っていない"
if echo "$list" | grep -q 'etc/rc.d/S[0-9]*brainwrt-data-grow$'; then
    fail "rootfs で brainwrt-data-grow が有効になっている"
fi

echo "PASS: test_data_grow_disabled.sh"
