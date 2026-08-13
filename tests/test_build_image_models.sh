#!/bin/sh
# scripts/build_image.sh の事前チェックの検証。
#
# 1 枚の SD を sh1-sh7 のどれでも起動できるようにするため、p1 には対象モデル
# ぶんの loader/gen3_N.bin・nk/eds*Nexe.bin・imx28-pwshN.dtb がすべて要る。
# BrainLILO は実機の型番から loader/gen3_N.bin を選ぶので、1 つでも欠けると
# その機種だけ「起動しない SD」が黙って出来上がる。
#
# ここでは欠けている状態を作り、build_image.sh がイメージを作る前に止まることを
# 確かめる。イメージを作ってから気づくのでは遅い（4GB 書いた後になる）。
set -ue

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# 対象は sh3 と sh5 の 2 機種。素材はすべて揃えておき、各ケースで 1 つだけ消す。
setup() {
    rm -rf "$WORK/boot" "$WORK/kernel" "$WORK/dtb" "$WORK/rootfs" "$WORK/out"
    mkdir -p "$WORK/boot/loader" "$WORK/boot/nk" "$WORK/boot/lilo" \
             "$WORK/kernel" "$WORK/dtb" "$WORK/rootfs" "$WORK/out"
    echo zImage > "$WORK/kernel/zImage"
    for n in 3 5; do
        echo "loader$n" > "$WORK/boot/loader/gen3_$n.bin"
        echo "dtb$n"    > "$WORK/dtb/imx28-pwsh$n.dtb"
    done
    # nk のファイル名は機種で綴りが違う（sh3=edsa3exe.bin、sh5=edsh5exe.bin）。
    echo nk3 > "$WORK/boot/nk/edsa3exe.bin"
    echo nk5 > "$WORK/boot/nk/edsh5exe.bin"
    for f in BrainLILO.dll BrainLILODrv.dll AppMain_.exe AppMain.exe; do
        echo lilo > "$WORK/boot/lilo/$f"
    done
}

# build_image.sh を走らせる。イメージ作成まで進んだかどうかも呼び出し側で見る。
run() {
    BRAIN_MODELS="sh3 sh5" \
    BRAINWRT_OUTPUT_DIR="$WORK/out" \
    BRAINWRT_BOOT_DIR="$WORK/boot" \
    BRAINWRT_KERNEL_DIR="$WORK/kernel" \
    BRAINWRT_DTB_DIR="$WORK/dtb" \
        "$REPO/scripts/build_image.sh" "$WORK/rootfs" test.img 240
}

# $1=消すファイル $2=ケース名
expect_early_failure() {
    setup
    rm -f "$1"
    if run >/dev/null 2>&1; then fail "$2 が欠けているのに成功した"; fi
    # dd までたどり着いていたらイメージが残る。事前チェックで止まっていない証拠。
    if [ -f "$WORK/out/test.img" ]; then
        fail "$2 が欠けているのに、止まる前にイメージを作ってしまった"
    fi
}

expect_early_failure "$WORK/boot/loader/gen3_5.bin" "sh5 の loader"
expect_early_failure "$WORK/boot/nk/edsh5exe.bin"   "sh5 の nk"
expect_early_failure "$WORK/dtb/imx28-pwsh5.dtb"    "sh5 の DTB"

echo "PASS: test_build_image_models.sh"
