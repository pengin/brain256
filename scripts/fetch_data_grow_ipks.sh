#!/bin/bash
# Fetch the resize2fs dependency closure for arm_arm926ej-s from the OpenWrt
# release feeds into cache/, verified against each feed's Packages index
# SHA256sum. Used by brainwrt-data-grow (on-device p3 resize) to grow /data
# to the real SD card's capacity at first boot without needing fdisk/sfdisk
# -- see profiles/imx28/overlay/etc/init.d/brainwrt-data-grow.
#
# Two feeds are needed: most packages live in the generic per-arch "base"
# feed, but musl's librt is only published in the target-specific "core"
# feed (confirmed on real PW-SH3 hardware: opkg reported "cannot find
# dependency librt" when only the base-feed closure was installed, even
# though librt isn't listed under packages/arm_arm926ej-s/base at all).
# resize2fs itself is also a separate
# package from e2fsprogs (OpenWrt splits each e2fsprogs binary into its
# own ipk; the main e2fsprogs package only ships mkfs/fsck/e2fsck).
set -ueo pipefail

VERSION="${OPENWRT_VERSION:-24.10.7}"
BASE_URL="https://downloads.openwrt.org/releases/${VERSION}/packages/arm_arm926ej-s/base"
CORE_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/mxs/generic/packages"

# Pinned filenames (version-locked; bump deliberately and re-verify against
# the feed if OPENWRT_VERSION changes).
BASE_PACKAGES="
e2fsprogs_1.47.0-r2_arm_arm926ej-s.ipk
resize2fs_1.47.0-r2_arm_arm926ej-s.ipk
libext2fs2_1.47.0-r2_arm_arm926ej-s.ipk
libe2p2_1.47.0-r2_arm_arm926ej-s.ipk
libblkid1_2.40.2-r1_arm_arm926ej-s.ipk
libcomerr0_1.47.0-r2_arm_arm926ej-s.ipk
libss2_1.47.0-r2_arm_arm926ej-s.ipk
libuuid1_2.40.2-r1_arm_arm926ej-s.ipk
"
CORE_PACKAGES="
librt_1.2.5-r4_arm_arm926ej-s.ipk
"

CACHE_DIR="$(cd "$(dirname "$0")/.." && pwd)/cache/data-grow-ipks"
mkdir -p "${CACHE_DIR}"

fetch_and_verify() {
    url="$1"
    pkg_index="$2"
    pkg="$3"
    IMG="${CACHE_DIR}/${pkg}"
    if [ -f "${IMG}" ]; then
        echo "Already cached: ${pkg}"
    else
        echo "Fetching ${url}/${pkg}"
        curl -fL --retry 3 -o "${IMG}.part" "${url}/${pkg}"
        mv "${IMG}.part" "${IMG}"
    fi

    EXPECTED=$(awk -v RS="" -v f="Filename: ${pkg}" '
        index($0, f) {
            n = split($0, lines, "\n")
            for (i = 1; i <= n; i++) if (lines[i] ~ /^SHA256sum:/) { print lines[i]; exit }
        }
    ' "${pkg_index}" | awk '{print $2}')
    [ -n "${EXPECTED}" ] || { echo "error: ${pkg} not in $(basename "${pkg_index}") index" >&2; exit 1; }

    ACTUAL=$(shasum -a 256 "${IMG}" 2>/dev/null | awk '{print $1}' || sha256sum "${IMG}" | awk '{print $1}')
    if [ "${EXPECTED}" != "${ACTUAL}" ]; then
        echo "error: sha256 mismatch for ${pkg}" >&2
        echo "  expected ${EXPECTED}" >&2
        echo "  actual   ${ACTUAL}" >&2
        exit 1
    fi
    echo "sha256 OK: ${pkg}"
}

curl -fL --retry 3 -o "${CACHE_DIR}/Packages.base" "${BASE_URL}/Packages"
curl -fL --retry 3 -o "${CACHE_DIR}/Packages.core" "${CORE_URL}/Packages"

for pkg in ${BASE_PACKAGES}; do
    fetch_and_verify "${BASE_URL}" "${CACHE_DIR}/Packages.base" "${pkg}"
done
for pkg in ${CORE_PACKAGES}; do
    fetch_and_verify "${CORE_URL}" "${CACHE_DIR}/Packages.core" "${pkg}"
done
