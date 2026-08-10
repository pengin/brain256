#!/bin/bash
# OpenWrt ImageBuilder で Brain の rootfs を作る（M0 の donor イメージ抽出を
# 置き換える M1 経路）。brainwrt-builder コンテナ内で --privileged を付けて実行する。
# loop device が必要なのは、下の sdcard-image fallback の場合だけである。
#
# ImageBuilder ツリーはコンテナ自身のファイルシステムへ展開する。デバイスノード
# は必要なく、macOS で扱えない要素を bind mount から遠ざけられる。
set -uex -o pipefail

PROFILE=${1:-imx28}
VERSION="${OPENWRT_VERSION:-24.10.7}"
DONOR="${OPENWRT_DONOR_PROFILE:-i2se_duckbill}"

REPO=/work
ROOTFS=${REPO}/rootfs
PROFILE_DIR=${REPO}/profiles/${PROFILE}
IB_TAR=${REPO}/cache/openwrt-imagebuilder-${VERSION}-mxs-generic.Linux-x86_64.tar.zst
OUT=${REPO}/output/rootfs-${PROFILE}.tar
IB_DIR=/ib

[ -f "${IB_TAR}" ] || { echo "error: run 'make fetch-ib' first (${IB_TAR} missing)" >&2; exit 1; }
[ -d "${PROFILE_DIR}" ] || { echo "error: unknown profile ${PROFILE}" >&2; exit 1; }

# --- 1. ImageBuilder を展開 -------------------------------------------------
mkdir -p ${IB_DIR}
bsdtar -xf "${IB_TAR}" -C ${IB_DIR} --strip-components=1

# デバイスイメージに加えて通常の rootfs tarball も生成させる。
echo 'CONFIG_TARGET_ROOTFS_TARGZ=y' >> ${IB_DIR}/.config

# --- 2. ビルド --------------------------------------------------------------
PACKAGES=$(grep -vE '^[[:space:]]*(#|$)' "${PROFILE_DIR}/packages.txt" | tr '\n' ' ')
make -C ${IB_DIR} image \
    PROFILE="${DONOR}" \
    PACKAGES="${PACKAGES}" \
    FILES="${PROFILE_DIR}/overlay"

BINDIR=${IB_DIR}/bin/targets/mxs/generic

# --- 3. rootfs ツリーを取得 --------------------------------------------------
# rootfs tarball を優先し、ImageBuilder が TARGZ を無視した場合は sdcard
# イメージの第 2 パーティションを取り出す処理へフォールバックする。
if ls ${BINDIR}/*rootfs.tar.gz >/dev/null 2>&1; then
    bsdtar -xpzf ${BINDIR}/*rootfs.tar.gz -C "${ROOTFS}"
else
    WORKIMG=$(mktemp -d)
    gunzip -c ${BINDIR}/*-${DONOR}-ext4-sdcard.img.gz > "${WORKIMG}/img"
    KPARTX_OUTPUT=$(kpartx -av "${WORKIMG}/img")
    LOOPDEV=$(echo "${KPARTX_OUTPUT}" | sed -n 's/^add map \(loop[0-9]*\)p.*/\1/p' | head -n1)
    mkdir -p "${WORKIMG}/p2"
    mount -o ro "/dev/mapper/${LOOPDEV}p2" "${WORKIMG}/p2"
    rsync -a "${WORKIMG}/p2/" "${ROOTFS}/"
    umount "${WORKIMG}/p2"
    kpartx -d "${WORKIMG}/img"
    rm -rf "${WORKIMG}"
fi

# --- 4. Brain 用に調整 ------------------------------------------------------
# M2 までは linux-brain の zImage を使うため、OpenWrt の kmod はロードできない。
rm -rf "${ROOTFS}/lib/modules" "${ROOTFS}/boot"/*

# --- 5. パッケージ化 --------------------------------------------------------
mkdir -p "$(dirname "${OUT}")"
bsdtar -cpf "${OUT}" -C "${ROOTFS}" .
du -sh "${ROOTFS}" || true
echo "Wrote ${OUT}"
