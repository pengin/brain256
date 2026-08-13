#!/bin/bash
# brainwrt 用 SD イメージビルダー。buildbrain の image/build_image.sh を
# モデル選択対応にした派生版。
#
# 派生元: https://github.com/brain-hackers/buildbrain
#   image/build_image.sh
#   Copyright (c) 2020 Takumi Sueda
#   Licensed under the MIT License.
# 改変部分の Copyright (c) 2026 pengin、ライセンスは同じく MIT。
# NOTICE.md 参照。
#
# brainwrt-builder 内で実行し、brain256 のリポジトリが /work に mount されている
# ものとする。Makefile の docker-image ターゲット参照。カーネル・U-Boot・BrainLILO は
# いずれもビルドせず、fetch-kernel と fetch-boot が取得したものを組み立てる。
#
# BRAIN_MODELS で U-Boot/nk.bin と DTB を作る Brain モデルを選ぶ。既定は手元の
# 実機だけである sh3。全モデルは次のとおり。
#   sh1 sh2 sh3 sh4 sh5 sh6 sh7
#   （a7200/a7400 は配布物が揃わないため本リポジトリでは扱わない）
#
# カーネル（zImage）とモデルごとの DTB は linux-brain（6.1.70）由来のもので、
# scripts/fetch_kernel.sh が buildbrain のリリースから取得する。本の 3.2 参照。
set -uex -o pipefail

show_help() {
    cat << 'EOF'
Usage: build_image.sh ROOTFS IMG_NAME SIZE_M

Build a bootable brainwrt SD image from prefetched artifacts.

Arguments:
  ROOTFS       Extracted rootfs directory (default: output/work/rootfs).
  IMG_NAME     Output image filename (created under output/).
  SIZE_M       Image size in megabytes.

Environment:
  BRAIN_MODELS         Space-separated model list (default: "sh3").
  BRAINWRT_OUTPUT_DIR  Output directory (default: /work/output).
  BRAINWRT_BOOT_DIR    Prebuilt bootloader dir (default: /work/cache/boot).
  BRAINWRT_KERNEL_DIR  Kernel dir (default: /work/cache/kernel).
  BRAINWRT_DTB_DIR     Patched DTB dir (default: /work/output/dtb).
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || -z "${1:-}" ]]; then
    show_help
    exit 0
fi

OUT=${BRAINWRT_OUTPUT_DIR:-/work/output}
WORK=${OUT}/work
ROOTFS=${1:-output/work/rootfs}
IMG_NAME=${2:-sd_wrt.img}
IMG=${OUT}/${IMG_NAME}
SIZE_M=${3:-512}
MODELS=${BRAIN_MODELS:-sh3}
# 起動用のビルド済みバイナリ。scripts/fetch_boot.sh が配置する。
BOOT_DIR=${BRAINWRT_BOOT_DIR:-/work/cache/boot}
KERNEL_DIR=${BRAINWRT_KERNEL_DIR:-/work/cache/kernel}
DTB_DIR=${BRAINWRT_DTB_DIR:-/work/output/dtb}

mkdir -p ${WORK}

# U-Boot と nk.bin はビルドせず、fetch_boot.sh が取得したものを使う。
# zip 内のファイル名は p1 での最終名と同じなので変換は要らない。
#
# BrainLILO は実機の型番から loader/gen3_N.bin を選ぶ。DTB は各モデルの U-Boot が
# fdt_file=imx28-pwshN.dtb として持っている。つまり 1 枚の SD を複数機種で起動
# させるには、対象モデルぶんの loader・nk・DTB がすべて要る。1 つでも欠けたまま
# 焼くと、その機種でだけ起動しない SD が黙って出来上がる。イメージを作る前に
# 揃っているか確かめる。
for i in ${MODELS}; do
    NUM=$(echo $i | sed -E 's/sh//g')
    [ -f "${BOOT_DIR}/loader/gen3_${NUM}.bin" ] \
        || { echo "ERROR: ${BOOT_DIR}/loader/gen3_${NUM}.bin がありません" >&2
             echo "  'make fetch-boot BRAIN_MODELS=\"${MODELS}\"' を先に実行してください" >&2; exit 1; }
    # nk のファイル名は機種で綴りが違う（sh3=edsa3exe.bin、sh5=edsh5exe.bin）。
    ls ${BOOT_DIR}/nk/eds*${NUM}exe.bin >/dev/null 2>&1 \
        || { echo "ERROR: ${BOOT_DIR}/nk/ に pw${i} の eds*${NUM}exe.bin がありません" >&2
             echo "  'make fetch-boot BRAIN_MODELS=\"${MODELS}\"' を先に実行してください" >&2; exit 1; }
    [ -f "${DTB_DIR}/imx28-pw${i}.dtb" ] \
        || { echo "ERROR: ${DTB_DIR}/imx28-pw${i}.dtb がありません" >&2
             echo "  'make docker-dtb BRAIN_MODELS=\"${MODELS}\"' を先に実行してください" >&2; exit 1; }
done

dd if=/dev/zero of=${IMG} bs=1M count=${SIZE_M}

# 3 パーティション: p1=boot(FAT)、p2=rootfs(固定)、p3=data(残り全部)。
# /data（brainwrt-ct のバンドル置き場）を rootfs から分離し、rootfs を再フラッシュ
# してもバンドル／データが残るようにする。p3 はイメージ内では残り全部だが、
# 初回ブートで SD カードの実容量まで拡張する（profiles の data-grow oneshot、
# 実機検証後に追加）。
START1=2048
SECTORS1=$((1024 * 1024 * 64 / 512))          # boot パーティション (64 MB)
ROOTFS_M=${ROOTFS_PART_M:-160}                # rootfs パーティションサイズ (MB)
SECTORS2=$((ROOTFS_M * 1024 * 1024 / 512))
START2=$((START1 + SECTORS1))
START3=$((START2 + SECTORS2))

MIN_M=$((64 + ROOTFS_M + 16))
if [ "${SIZE_M}" -lt "${MIN_M}" ]; then
    echo "ERROR: SIZE_M=${SIZE_M} too small; need >= ${MIN_M}" >&2
    echo "  (64 boot + ${ROOTFS_M} rootfs + data slack; set ROOTFS_PART_M/SIZE_M)" >&2
    exit 1
fi

cat <<EOF > ${WORK}/part.sfdisk
${IMG}1 : start=${START1}, size=${SECTORS1}, type=b
${IMG}2 : start=${START2}, size=${SECTORS2}, type=83
${IMG}3 : start=${START3}, type=83
EOF

sfdisk ${IMG} < ${WORK}/part.sfdisk

KPARTX_OUTPUT=$(sudo kpartx -av ${IMG})
LOOPDEV=$(echo "${KPARTX_OUTPUT}" | sed -n 's/^add map \(loop[0-9]\+\)p1.*/\1/p' | head -n 1)

sudo mkfs.fat -n boot -F32 -v -I /dev/mapper/${LOOPDEV}p1
sudo mkfs.ext4 -L rootfs /dev/mapper/${LOOPDEV}p2
sudo mkfs.ext4 -L data /dev/mapper/${LOOPDEV}p3

mkdir -p ${WORK}/p1 ${WORK}/p2
sudo mount -o utf8=true /dev/mapper/${LOOPDEV}p1 ${WORK}/p1
sudo mount /dev/mapper/${LOOPDEV}p2 ${WORK}/p2

echo ${BRAINWRT_VERSION:-unknown} > ${WORK}/brainwrt_version
sudo cp ${WORK}/brainwrt_version ${WORK}/p1/

echo "kernel: ${KERNEL_DIR}/zImage"
sudo cp "${KERNEL_DIR}/zImage" ${WORK}/p1/

# 存在は冒頭の事前チェックで確かめてある。ここは配置するだけ。
for i in ${MODELS}; do
    echo "dtb (pw${i}): patched (${DTB_DIR})"
    sudo cp "${DTB_DIR}/imx28-pw${i}.dtb" ${WORK}/p1/
done

sudo mkdir -p ${WORK}/p1/nk
sudo cp ${BOOT_DIR}/nk/*.bin ${WORK}/p1/nk/

# ステージング済みの .ipk があればブートパーティションへ置き、ネットワークなしで
# 実機にインストールできるようにする（Brain 自体には Ethernet も Wi-Fi もない）。
# 実行前に output/ipk/ へ置く。ディレクトリがないか空なら省略する。
IPK_DIR=${IPK_DIR:-/work/output/ipk}
if ls ${IPK_DIR}/*.ipk >/dev/null 2>&1; then
    sudo cp ${IPK_DIR}/*.ipk ${WORK}/p1/
fi

# BrainLILO もビルドせず fetch_boot.sh が取得したものを使う。
# AppMain_.exe は BrainLILO 本体、AppMain.exe は exeopener である。入れ替えると起動しない。
LILO="${WORK}/p1/アプリ/Launch Linux"
sudo mkdir -p "${LILO}"
sudo touch "${LILO}/index.din"
sudo touch "${LILO}/AppMain.cfg"
sudo cp ${BOOT_DIR}/lilo/BrainLILO.dll "${LILO}/"
sudo cp ${BOOT_DIR}/lilo/BrainLILODrv.dll "${LILO}/"
sudo cp ${BOOT_DIR}/lilo/AppMain_.exe "${LILO}/"
sudo cp ${BOOT_DIR}/lilo/AppMain.exe "${LILO}/"

sudo mkdir -p ${WORK}/p1/loader
sudo cp ${BOOT_DIR}/loader/*.bin ${WORK}/p1/loader/

sudo cp -a "${ROOTFS}/." "${WORK}/p2/"

sudo umount ${WORK}/p1 ${WORK}/p2
sudo kpartx -d ${IMG}

rmdir ${WORK}/p1 ${WORK}/p2
