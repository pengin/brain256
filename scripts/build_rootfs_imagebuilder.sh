#!/bin/bash
# Build the Brain rootfs with the OpenWrt ImageBuilder (M1 flow,
# replacing the donor-image extraction of M0). Runs inside the
# brainwrt-builder container with --privileged (loop devices are
# needed only for the sdcard-image fallback below).
#
# The ImageBuilder tree is extracted into the container's own
# filesystem: it never needs device nodes, and this keeps the
# macOS-unsafe bits off bind mounts.
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

# --- 1. Unpack the ImageBuilder ---------------------------------------------
mkdir -p ${IB_DIR}
bsdtar -xf "${IB_TAR}" -C ${IB_DIR} --strip-components=1

# Ask for a plain rootfs tarball in addition to the device images.
echo 'CONFIG_TARGET_ROOTFS_TARGZ=y' >> ${IB_DIR}/.config

# --- 2. Build ------------------------------------------------------------------
PACKAGES=$(grep -vE '^\s*(#|$)' "${PROFILE_DIR}/packages.txt" | tr '\n' ' ')
make -C ${IB_DIR} image \
    PROFILE="${DONOR}" \
    PACKAGES="${PACKAGES}" \
    FILES="${PROFILE_DIR}/overlay"

BINDIR=${IB_DIR}/bin/targets/mxs/generic

# --- 3. Obtain the rootfs tree ---------------------------------------------------
# Prefer the rootfs tarball; fall back to extracting the sdcard image's
# second partition if this ImageBuilder ignores TARGZ.
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

# --- 4. Adapt for Brain -----------------------------------------------------------
# Kernel stays linux-brain's zImage until M2; OpenWrt kmods can't load.
rm -rf "${ROOTFS}/lib/modules" "${ROOTFS}/boot"/*

# --- 5. Pack ------------------------------------------------------------------------
mkdir -p "$(dirname "${OUT}")"
bsdtar -cpf "${OUT}" -C "${ROOTFS}" .
du -sh "${ROOTFS}" || true
echo "Wrote ${OUT}"
