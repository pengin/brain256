#!/bin/bash
# donor SD イメージから OpenWrt の rootfs を取り出し、Brain 用 rootfs tarball に
# 整形する。brainwrt-builder コンテナ内で実行する（Makefile の docker-rootfs 参照）。
# loop device 用の --privileged と、Linux ファイルシステム上の /work/rootfs
#（named volume、APFS ではない）が必要。
set -uex -o pipefail

PROFILE=${1:-imx28}
VERSION="${OPENWRT_VERSION:-24.10.7}"
DONOR="${OPENWRT_DONOR_PROFILE:-i2se_duckbill}"

REPO=/work
ROOTFS=${REPO}/rootfs
PROFILE_DIR=${REPO}/profiles/${PROFILE}
IMG_GZ=${REPO}/cache/openwrt-${VERSION}-mxs-generic-${DONOR}-ext4-sdcard.img.gz
OUT=${REPO}/output/rootfs-${PROFILE}.tar
WORK=$(mktemp -d)

[ -f "${IMG_GZ}" ] || { echo "error: run 'make fetch' first (${IMG_GZ} missing)" >&2; exit 1; }
[ -d "${PROFILE_DIR}" ] || { echo "error: unknown profile ${PROFILE}" >&2; exit 1; }

cleanup() {
    umount "${WORK}/p2" 2>/dev/null || true
    [ -n "${LOOPDEV:-}" ] && kpartx -d "${WORK}/donor.img" 2>/dev/null || true
    rm -rf "${WORK}"
}
trap cleanup EXIT

# --- 1. donor イメージの rootfs パーティションをマウント -----------------
gunzip -c "${IMG_GZ}" > "${WORK}/donor.img"
KPARTX_OUTPUT=$(kpartx -av "${WORK}/donor.img")
LOOPDEV=$(echo "${KPARTX_OUTPUT}" | sed -n 's/^add map \(loop[0-9]*\)p.*/\1/p' | head -n1)
mkdir -p "${WORK}/p2"
mount -o ro "/dev/mapper/${LOOPDEV}p2" "${WORK}/p2"

# --- 2. rootfs を取り出す --------------------------------------------------
rsync -a "${WORK}/p2/" "${ROOTFS}/"
umount "${WORK}/p2"

# --- 3. Brain 用に調整 ------------------------------------------------------
# カーネルは OpenWrt のものではなく、ドライバを組み込んだ linux-brain の zImage
# を使う。そのため同梱されたカーネルモジュールはロードできず、削除する。
rm -rf "${ROOTFS}/lib/modules" "${ROOTFS}/boot"/*

rsync -a "${PROFILE_DIR}/overlay/" "${ROOTFS}/"

# --- 3.5. p3 オンデバイス resize 用 e2fsprogs 一式を同梱 --------------------
IPK_CACHE="${REPO}/cache/data-grow-ipks"
[ -d "${IPK_CACHE}" ] || { echo "error: run './scripts/fetch_data_grow_ipks.sh' first (${IPK_CACHE} missing)" >&2; exit 1; }
mkdir -p "${ROOTFS}/usr/share/brainwrt-data-grow"
cp "${IPK_CACHE}"/*.ipk "${ROOTFS}/usr/share/brainwrt-data-grow/"

# --- 4. パッケージ化 --------------------------------------------------------
mkdir -p "$(dirname "${OUT}")"
bsdtar -cpf "${OUT}" -C "${ROOTFS}" .
du -sh "${ROOTFS}" || true
echo "Wrote ${OUT}"
