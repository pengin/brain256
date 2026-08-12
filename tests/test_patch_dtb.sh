#!/bin/sh
# scripts/patch_dtb.sh の検証。dtc と fdtput/fdtget が要る。
# ホストに無い場合は SKIP する（make docker-test-dtb で実行できる）。
set -ue

REPO=$(cd "$(dirname "$0")/.." && pwd)
for t in dtc fdtput fdtget; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "SKIP: $t がない (make docker-test-dtb で実行してください)"; exit 0; }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/src"; OUT="$WORK/out"; OUT2="$WORK/out2"
mkdir -p "$SRC"

# 実機の imx28 と同じノードパスを持つ最小の DTB を作る
cat > "$WORK/min.dts" <<'DTS'
/dts-v1/;
/ {
	#address-cells = <1>;
	#size-cells = <1>;
	ahb@80080000 {
		#address-cells = <1>;
		#size-cells = <1>;
		usb@80080000 {
			compatible = "fsl,imx28-usb";
			status = "okay";
			dr_mode = "host";
		};
	};
};
DTS
dtc -I dts -O dtb -S 4096 -o "$SRC/imx28-pwsh3.dtb" "$WORK/min.dts" 2>/dev/null

fail() { echo "FAIL: $1"; exit 1; }

# 1. 未パッチの DTB がパッチされる
BRAIN_MODELS=sh3 DTB_SRC_DIR="$SRC" DTB_OUT_DIR="$OUT" \
    "$REPO/scripts/patch_dtb.sh" imx28 >/dev/null || fail "パッチ処理が失敗した"
[ "$(fdtget "$OUT/imx28-pwsh3.dtb" /ahb@80080000/usb@80080000 dr_mode)" = "otg" ] \
    || fail "dr_mode が otg になっていない"
fdtget -p "$OUT/imx28-pwsh3.dtb" /ahb@80080000/usb@80080000 \
    | grep -qx "usb-role-switch" || fail "usb-role-switch がない"

# 入力を書き換えていないこと
[ "$(fdtget "$SRC/imx28-pwsh3.dtb" /ahb@80080000/usb@80080000 dr_mode)" = "host" ] \
    || fail "入力の DTB を書き換えてしまった"

# 2. 冪等性: パッチ済みを入力にしても壊れない（出力先は別にする。同じにすると
#    スクリプトの cp が「同一ファイル」で失敗するため）
BRAIN_MODELS=sh3 DTB_SRC_DIR="$OUT" DTB_OUT_DIR="$OUT2" \
    "$REPO/scripts/patch_dtb.sh" imx28 >/dev/null || fail "2 回目の処理が失敗した"
[ "$(fdtget "$OUT2/imx28-pwsh3.dtb" /ahb@80080000/usb@80080000 dr_mode)" = "otg" ] \
    || fail "2 回目で dr_mode が壊れた"
fdtget -p "$OUT2/imx28-pwsh3.dtb" /ahb@80080000/usb@80080000 \
    | grep -qx "usb-role-switch" || fail "2 回目で usb-role-switch が消えた"

# 3. ノードが無い DTB は非ゼロで終わる
printf '/dts-v1/;\n/ { foo { }; };\n' > "$WORK/bad.dts"
dtc -I dts -O dtb -o "$SRC/imx28-pwsh3.dtb" "$WORK/bad.dts" 2>/dev/null
if BRAIN_MODELS=sh3 DTB_SRC_DIR="$SRC" DTB_OUT_DIR="$OUT" \
        "$REPO/scripts/patch_dtb.sh" imx28 >/dev/null 2>&1; then
    fail "ノードが無いのに成功してしまった"
fi

echo "PASS: test_patch_dtb.sh"
