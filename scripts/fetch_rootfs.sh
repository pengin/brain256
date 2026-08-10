#!/bin/bash
# donor 用 OpenWrt SD イメージ（mxs/generic）を cache/ に取得し、リリースが公開する
# 署名済みチェックサム一覧で sha256 を検証する。
#
# mxs/generic は単独の rootfs tarball を公開していないため、別の i.MX28 ボード
# である i2se_duckbill のイメージから rootfs パーティションを借り、
# build_rootfs.sh で取り出す。ユーザーランドは汎用の arm_arm926ej-s である。
set -ueo pipefail

VERSION="${OPENWRT_VERSION:-24.10.7}"
DONOR="${OPENWRT_DONOR_PROFILE:-i2se_duckbill}"
BASE_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/mxs/generic"
IMG_NAME="openwrt-${VERSION}-mxs-generic-${DONOR}-ext4-sdcard.img.gz"

CACHE_DIR="$(cd "$(dirname "$0")/.." && pwd)/cache"
mkdir -p "${CACHE_DIR}"
IMG="${CACHE_DIR}/${IMG_NAME}"

if [ -f "${IMG}" ]; then
    echo "Already cached: ${IMG}"
else
    echo "Fetching ${BASE_URL}/${IMG_NAME}"
    curl -fL --retry 3 -o "${IMG}.part" "${BASE_URL}/${IMG_NAME}"
    mv "${IMG}.part" "${IMG}"
fi

curl -fL --retry 3 -o "${CACHE_DIR}/sha256sums" "${BASE_URL}/sha256sums"
EXPECTED=$(grep "[* ]${IMG_NAME}\$" "${CACHE_DIR}/sha256sums" | awk '{print $1}')
[ -n "${EXPECTED}" ] || { echo "error: ${IMG_NAME} not in sha256sums — check OPENWRT_VERSION/OPENWRT_DONOR_PROFILE" >&2; exit 1; }

ACTUAL=$(shasum -a 256 "${IMG}" 2>/dev/null | awk '{print $1}' || sha256sum "${IMG}" | awk '{print $1}')
if [ "${EXPECTED}" != "${ACTUAL}" ]; then
    echo "error: sha256 mismatch for ${IMG_NAME}" >&2
    echo "  expected ${EXPECTED}" >&2
    echo "  actual   ${ACTUAL}" >&2
    exit 1
fi
echo "sha256 OK: ${IMG_NAME}"
