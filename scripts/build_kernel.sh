#!/bin/bash
# linux-brain をピン留めコミットでビルドし、配布用の zip を作る。
# メンテナ専用。読者はこれを実行せず、make fetch-kernel で成果物を取得する。
#
# コンテナ内(brainwrt-kernel-builder)で実行される前提。Makefile の
# kernel-release ターゲットを参照。
set -ueo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
COMMIT="${LINUX_BRAIN_COMMIT:-5ccf14be66a6549f9b779b3f8c38dd9160a7d388}"
VERSION="${KERNEL_VERSION:-6.1.70-1}"
BUILD_DIR="${KERNEL_BUILD_DIR:-${REPO}/output/kernel-build}"
SRC="${LINUX_BRAIN_DIR:-}"
OUT="${REPO}/output/kernel-release"
# brain-hackers/linux-brain ではなく fork を指す。ピン留めコミットは本リポジトリ作者の
# 変更(コンテナ設定と usb-role-switch の DTS)を含み、上流には入っていないため。
# 上流へ取り込まれたら、この既定値を戻す。
URL="${LINUX_BRAIN_URL:-https://github.com/pengin/linux-brain}"
MODELS="sh1 sh2 sh3 sh4 sh5 sh6 sh7 a7200 a7400"

export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabi-
JOBS="${JOBS:-$(nproc)}"

# --- 1. ソースを用意する -------------------------------------------------
if [ -n "${SRC}" ]; then
    # 既存ツリーを使う場合、ピン留めコミットと一致していることを必ず確かめる。
    # 別のコミットから作ったカーネルを、ピン留めした版として配布しないため。
    #
    # 注意: buildbrain の linux-brain は submodule で、.git は
    # ../.git/modules/linux-brain を指すファイルである。コンテナへ渡すときは
    # サブモジュールだけでなく親リポジトリごと mount しないと git が解決できない。
    #   -v /path/to/buildbrain:/buildbrain -e LINUX_BRAIN_DIR=/buildbrain/linux-brain
    HEAD_SHA=$(git -C "${SRC}" rev-parse HEAD)
    if [ "${HEAD_SHA}" != "${COMMIT}" ]; then
        echo "error: ${SRC} の HEAD が ${HEAD_SHA} で、ピン留め ${COMMIT} と違います" >&2
        exit 1
    fi
    echo "linux-brain: 既存ツリーを使います (${SRC})"
else
    SRC="${BUILD_DIR}/linux-brain"
    if [ ! -d "${SRC}/.git" ]; then
        echo "linux-brain: ${COMMIT} を取得します"
        mkdir -p "${SRC}"
        git -C "${SRC}" init -q
        git -C "${SRC}" remote add origin "${URL}"
        git -C "${SRC}" fetch -q --depth 1 origin "${COMMIT}"
        git -C "${SRC}" checkout -q FETCH_HEAD
    fi
fi

# --- 2. ビルドする -------------------------------------------------------
# buildbrain の ldefconfig / lbuild と同じ手順に揃える。
echo "kernel: brain_defconfig でビルドします (jobs=${JOBS})"
make -C "${SRC}" brain_defconfig
make -C "${SRC}" -j"${JOBS}"

# --- 3. 検証する ---------------------------------------------------------
# ここが今回の障害(overlayfs 欠落)を二度と起こさないための歯止めである。
BOOT="${SRC}/arch/arm/boot"
[ -f "${BOOT}/zImage" ] || { echo "error: zImage がありません" >&2; exit 1; }

for m in ${MODELS}; do
    [ -f "${BOOT}/dts/imx28-pw${m}.dtb" ] \
        || { echo "error: imx28-pw${m}.dtb がありません" >&2; exit 1; }
done
echo "検証: zImage と DTB ${MODELS} を確認しました"

# sh1-sh7 は DTS の時点で dual-role になっているはずである。1 機種だけ見ると
# 他の機種の抜けを拾えないので、7 機種すべてを確認する。
# a7200/a7400 は host のまま据え置くため、この検査の対象外。
NODE=/ahb@80080000/usb@80080000
for m in sh1 sh2 sh3 sh4 sh5 sh6 sh7; do
    DTB="${BOOT}/dts/imx28-pw${m}.dtb"
    DR=$(fdtget "${DTB}" "${NODE}" dr_mode)
    [ "${DR}" = "otg" ] \
        || { echo "error: imx28-pw${m}.dtb の dr_mode が ${DR} です (otg であるべき)" >&2; exit 1; }
    fdtget -p "${DTB}" "${NODE}" | grep -qx usb-role-switch \
        || { echo "error: imx28-pw${m}.dtb に usb-role-switch がありません" >&2; exit 1; }
done
echo "検証: sh1-sh7 の usb0 は dr_mode=otg + usb-role-switch です"

for sym in CONFIG_OVERLAY_FS CONFIG_PID_NS CONFIG_MEMCG; do
    grep -qx "${sym}=y" "${SRC}/.config" \
        || { echo "error: ${sym}=y が .config にありません (brainwrt-ct が動きません)" >&2; exit 1; }
done
echo "検証: コンテナ基盤に必要な設定を確認しました"

# --- 4. zip に固める -----------------------------------------------------
# 上流のリリースと同じく release/ を 1 階層挟む。fetch_kernel.sh の展開処理を
# そのまま使えるようにするため。
STAGE="${BUILD_DIR}/stage"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/release"
cp "${BOOT}/zImage" "${STAGE}/release/"
for m in ${MODELS}; do
    cp "${BOOT}/dts/imx28-pw${m}.dtb" "${STAGE}/release/"
done
# GPL-2.0 が求める「コンパイルを制御するスクリプト一式」として .config を同梱する。
cp "${SRC}/.config" "${STAGE}/release/config"

mkdir -p "${OUT}"
ZIP="${OUT}/brain256-kernel-${VERSION}.zip"
rm -f "${ZIP}"
(cd "${STAGE}" && zip -qr "${ZIP}" release)

echo "kernel: ${ZIP} を作りました"
(cd "${OUT}" && sha256sum "brain256-kernel-${VERSION}.zip" 2>/dev/null \
    || shasum -a 256 "brain256-kernel-${VERSION}.zip")
