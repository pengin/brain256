#!/bin/bash
# Fetch the OpenWrt ImageBuilder for mxs/generic into cache/ and verify
# its sha256 against the release checksum list.
set -ueo pipefail

VERSION="${OPENWRT_VERSION:-24.10.7}"
BASE_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/mxs/generic"
IB_NAME="openwrt-imagebuilder-${VERSION}-mxs-generic.Linux-x86_64.tar.zst"

CACHE_DIR="$(cd "$(dirname "$0")/.." && pwd)/cache"
mkdir -p "${CACHE_DIR}"
IB="${CACHE_DIR}/${IB_NAME}"

if [ -f "${IB}" ]; then
    echo "Already cached: ${IB}"
else
    echo "Fetching ${BASE_URL}/${IB_NAME}"
    curl -fL --retry 3 -o "${IB}.part" "${BASE_URL}/${IB_NAME}"
    mv "${IB}.part" "${IB}"
fi

curl -fL --retry 3 -o "${CACHE_DIR}/sha256sums" "${BASE_URL}/sha256sums"
EXPECTED=$(grep "[* ]${IB_NAME}\$" "${CACHE_DIR}/sha256sums" | awk '{print $1}')
[ -n "${EXPECTED}" ] || { echo "error: ${IB_NAME} not in sha256sums" >&2; exit 1; }

ACTUAL=$(shasum -a 256 "${IB}" 2>/dev/null | awk '{print $1}' || sha256sum "${IB}" | awk '{print $1}')
if [ "${EXPECTED}" != "${ACTUAL}" ]; then
    echo "error: sha256 mismatch for ${IB_NAME}" >&2
    exit 1
fi
echo "sha256 OK: ${IB_NAME}"
