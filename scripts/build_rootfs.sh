#!/bin/bash
# Extract the OpenWrt rootfs from the donor SD image and shape it into
# the Brain rootfs tarball. Runs inside the brainwrt-builder container
# (see Makefile docker-rootfs): needs --privileged for loop devices and
# /work/rootfs on a Linux filesystem (named volume, never APFS).
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

# --- 1. Mount the donor image's rootfs partition ---------------------------
gunzip -c "${IMG_GZ}" > "${WORK}/donor.img"
KPARTX_OUTPUT=$(kpartx -av "${WORK}/donor.img")
LOOPDEV=$(echo "${KPARTX_OUTPUT}" | sed -n 's/^add map \(loop[0-9]*\)p.*/\1/p' | head -n1)
mkdir -p "${WORK}/p2"
mount -o ro "/dev/mapper/${LOOPDEV}p2" "${WORK}/p2"

# --- 2. Copy out the rootfs --------------------------------------------------
rsync -a "${WORK}/p2/" "${ROOTFS}/"
umount "${WORK}/p2"

# --- 3. Adapt for Brain -------------------------------------------------------
# The kernel is linux-brain's zImage (drivers built in), not OpenWrt's:
# the bundled kernel modules can never load, so drop them.
rm -rf "${ROOTFS}/lib/modules" "${ROOTFS}/boot"/*

rsync -a "${PROFILE_DIR}/overlay/" "${ROOTFS}/"

# --- 3.5. p3 オンデバイス resize 用 e2fsprogs 一式を同梱 --------------------
IPK_CACHE="${REPO}/cache/data-grow-ipks"
[ -d "${IPK_CACHE}" ] || { echo "error: run './scripts/fetch_data_grow_ipks.sh' first (${IPK_CACHE} missing)" >&2; exit 1; }
mkdir -p "${ROOTFS}/usr/share/brainwrt-data-grow"
cp "${IPK_CACHE}"/*.ipk "${ROOTFS}/usr/share/brainwrt-data-grow/"

# --- 4. Pack -------------------------------------------------------------------
mkdir -p "$(dirname "${OUT}")"
bsdtar -cpf "${OUT}" -C "${ROOTFS}" .
du -sh "${ROOTFS}" || true
echo "Wrote ${OUT}"
