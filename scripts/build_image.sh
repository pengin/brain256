#!/bin/bash
# SD image builder for brainwrt — a model-selectable derivative of
# buildbrain's image/build_image.sh.
#
# Derived from https://github.com/brain-hackers/buildbrain
#   image/build_image.sh
#   Copyright (c) 2020 Takumi Sueda
#   Licensed under the MIT License.
# Modifications Copyright (c) 2026 pengin, also under the MIT License.
# See NOTICE.md.
#
# Runs inside buildbrain-builder:local with the buildbrain repo at
# BUILDBRAIN_ROOT (default /work); see the Makefile's docker-image
# target.
#
# BRAIN_MODELS selects which Brain models to build U-Boot/nk.bin and
# DTBs for (default: sh3 — the only device on hand). The full set is:
#   a7200 a7400 sh1 sh2 sh3 sh4 sh5 sh6 sh7
#
# The kernel (zImage) and the per-model DTBs come from linux-brain
# (6.1.70), built in the buildbrain tree — see the book's 3.2.
set -uex -o pipefail

show_help() {
    cat << 'EOF'
Usage: build_image.sh ROOTFS IMG_NAME SIZE_M

Build a bootable brainwrt SD image using buildbrain's artifacts.

Arguments:
  ROOTFS       Rootfs directory relative to the buildbrain repo root.
  IMG_NAME     Output image filename (created under buildbrain/image/).
  SIZE_M       Image size in megabytes.

Environment:
  BRAIN_MODELS     Space-separated model list (default: "sh3").
  BUILDBRAIN_ROOT  buildbrain repo root (default: /work).
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || -z "${1:-}" ]]; then
    show_help
    exit 0
fi

JOBS=${IMG_BUILD_JOBS:-$(nproc)}
REPO=${BUILDBRAIN_ROOT:-/work}
WORK=${REPO}/image/work
LINUX=${REPO}/linux-brain
ROOTFS=${1:-rootfs}
IMG_NAME=${2:-sd_wrt.img}
IMG=${REPO}/image/${IMG_NAME}
SIZE_M=${3:-512}
MODELS=${BRAIN_MODELS:-sh3}
export CROSS_COMPILE=arm-linux-gnueabi-

mkdir -p ${WORK}
mkdir -p ${WORK}/lilobin
# Stale payloads from a previous (possibly all-model) run would leak
# into p1/nk and p1/loader via the wildcard copies below.
rm -f ${WORK}/*.bin ${WORK}/lilobin/*.bin

for i in ${MODELS}; do
    NUM=$(echo $i | sed -E 's/sh//g')
    BUILD_DIR=${WORK}/uboot-build-${i}

    rm -rf ${BUILD_DIR}
    rsync -a --exclude '.git' ${REPO}/u-boot-brain/ ${BUILD_DIR}/
    make -C ${BUILD_DIR} pw${i}_defconfig
    make -j${JOBS} -C ${BUILD_DIR} u-boot.bin
    ${REPO}/nkbin_maker/bsd-ce ${BUILD_DIR}/u-boot.bin

    case $i in
        "a7200")
            mv ${REPO}/nk.bin ${WORK}/edna3exe.bin
            mv ${BUILD_DIR}/u-boot.bin ${WORK}/lilobin/gen2.bin;;
        "a7400")
            mv ${BUILD_DIR}/u-boot.bin ${WORK}/lilobin/gen2_7400.bin;;
        "sh1" | "sh2" | "sh3")
            mv ${REPO}/nk.bin ${WORK}/edsa${NUM}exe.bin
            mv ${BUILD_DIR}/u-boot.bin ${WORK}/lilobin/gen3_${NUM}.bin;;
        "sh4" | "sh5" | "sh6" | "sh7")
            mv ${REPO}/nk.bin ${WORK}/edsh${NUM}exe.bin
            mv ${BUILD_DIR}/u-boot.bin ${WORK}/lilobin/gen3_${NUM}.bin;;
        *)
            echo "unknown model: $i"
            exit 1;;
    esac
done

dd if=/dev/zero of=${IMG} bs=1M count=${SIZE_M}

# 3 パーティション: p1=boot(FAT), p2=rootfs(ext4, 固定), p3=data(ext4, 残り)。
# /data(brainwrt-ct のバンドル置場)を rootfs から分離し、rootfs 再フラッシュでも
# バンドル/データが残るようにする。p3 はイメージ内では残り全部だが、初回ブートで
# SD カードの実容量まで拡張する(profiles の datafs oneshot、実機検証後に追加)。
START1=2048
SECTORS1=$((1024 * 1024 * 64 / 512))          # 64MB boot
ROOTFS_M=${ROOTFS_PART_M:-160}                # rootfs partition size (MB)
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

echo "kernel: linux-brain (${LINUX}/arch/arm/boot/zImage)"
sudo cp ${LINUX}/arch/arm/boot/zImage ${WORK}/p1/

for i in ${MODELS}; do
    echo "dtb (pw${i}): linux-brain"
    sudo cp ${LINUX}/arch/arm/boot/dts/imx28-pw${i}.dtb ${WORK}/p1/
done
sudo mkdir -p ${WORK}/p1/nk
sudo cp ${WORK}/*.bin ${WORK}/p1/nk/

# Bundle any staged .ipk files so the on-device m0test script can
# install them without a network (see profiles/*/overlay/usr/bin/m0test).
IPK_DIR=${IPK_DIR:-/brainwrt-output/ipk}
if ls ${IPK_DIR}/*.ipk >/dev/null 2>&1; then
    sudo cp ${IPK_DIR}/*.ipk ${WORK}/p1/
fi

make -C ${REPO}/brainlilo

LILO="${WORK}/p1/アプリ/Launch Linux"
sudo mkdir -p "${LILO}"
sudo touch "${LILO}/index.din"
sudo touch "${LILO}/AppMain.cfg"
sudo cp ${REPO}/brainlilo/*.dll "${LILO}/"
sudo cp ${REPO}/brainlilo/BrainLILO.exe "${LILO}/AppMain_.exe"
gzip -cd ${REPO}/image/exeopener.exe.gz > ${REPO}/image/exeopener.exe
sudo cp ${REPO}/image/exeopener.exe "${LILO}/AppMain.exe"

sudo mkdir -p ${WORK}/p1/loader
sudo cp ${WORK}/lilobin/*.bin ${WORK}/p1/loader/

sudo cp -a "${REPO}/${ROOTFS}/." "${WORK}/p2/"

sudo umount ${WORK}/p1 ${WORK}/p2
sudo kpartx -d ${IMG}

rmdir ${WORK}/p1 ${WORK}/p2
