#!/bin/bash
# Build a bundle's binary payload: install bundles/<name>/packages.txt
# via the OpenWrt ImageBuilder's opkg into an offline-root staging
# tree, then merge the resulting usr/bin, usr/lib, lib, usr/sbin into
# bundles/<name>/root/ (existing overlay files such as webcam-run,
# index.html, manifest.conf are untouched -- opkg only ever adds under
# usr/ and lib/).
#
# The ImageBuilder's own opkg (staging_dir/host/bin/opkg) is an
# x86_64 Linux binary (a wrapper script that exec's a bundled
# ld-linux-x86-64.so.2 + .opkg.bin) -- it cannot run on macOS, so the
# opkg calls run inside `docker run --platform linux/amd64` against
# buildbrain-builder:local (already used by the other brainwrt build
# scripts and confirmed to have outbound network access, which opkg
# needs to fetch fswebcam + deps from downloads.openwrt.org).
#
# Extraction of the cached ImageBuilder tarball and the opkg staging
# root both happen in a throwaway scratch dir (mktemp -d), never in
# the repo tree.
set -ueo pipefail

name="${1:?usage: build_bundle.sh <name>}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bdir="${REPO_ROOT}/bundles/${name}"
[ -f "${bdir}/packages.txt" ] || { echo "no ${bdir}/packages.txt" >&2; exit 1; }
pkgs="$(grep -vE '^\s*#|^\s*$' "${bdir}/packages.txt" | tr '\n' ' ')"
[ -n "${pkgs}" ] || { echo "error: ${bdir}/packages.txt has no packages" >&2; exit 1; }

VERSION="${OPENWRT_VERSION:-24.10.7}"
IB_TAR="${IB_TAR:-${REPO_ROOT}/cache/openwrt-imagebuilder-${VERSION}-mxs-generic.Linux-x86_64.tar.zst}"
[ -f "${IB_TAR}" ] || { echo "error: ${IB_TAR} missing -- run 'make fetch-ib' first" >&2; exit 1; }

DOCKER_IMAGE="${BUILDBRAIN_DOCKER_IMAGE:-buildbrain-builder:local}"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/build_bundle.${name}.XXXXXX")"
cleanup() { rm -rf "${scratch}"; }
trap cleanup EXIT

echo "build_bundle: scratch=${scratch}"

# --- 1. Extract the cached ImageBuilder --------------------------------
# The tarball is zstd-compressed; the buildbrain-builder container's
# GNU tar (1.35, no zstd binary on PATH) can't decompress it, so this
# runs on the host, where zstd/unzstd is available (Homebrew).
mkdir -p "${scratch}/ib"
zstd -dc "${IB_TAR}" | tar -xf - -C "${scratch}/ib" --strip-components=1

# --- 2. Sanitize repositories.conf for offline-root use ------------------
# Two edits, both documented workarounds for running opkg standalone
# (outside `make image`) with --offline-root:
#   - drop the trailing "option check_signature": offline-root installs
#     fail signature verification without the ImageBuilder's usign trust
#     store set up; accepted workaround per the task brief.
#   - drop "src imagebuilder file:packages": that path is relative to
#     opkg's cwd (not the conf file) and points at IB's local/empty
#     packages/ dir (a placeholder for user-added .ipks per its
#     README) -- it only ever fails to resolve here and isn't needed to
#     reach the real remote feeds.
grep -v -e '^option check_signature' -e '^src imagebuilder' \
    "${scratch}/ib/repositories.conf" > "${scratch}/repositories.conf"

# --- 3. Locate the arch and the ImageBuilder's bundled libc .ipk --------
# opkg's dependency resolver requires a "libc" package to be resolvable
# for essentially every target package (fswebcam, libgd, ... all
# Depend: libc), but libc is deliberately NOT published in the remote
# feeds for this target: it's specific to the ImageBuilder's own
# toolchain build and ships pre-built inside the ImageBuilder tarball
# itself (under build_dir/), because the base rootfs it assembles
# already has libc built in. It's also already part of Brain's base
# image (same OpenWrt release, donor-extracted) so this bundle doesn't
# strictly need to ship it -- but it must be *installed into the opkg
# offline-root* first so opkg's own dependency resolution is satisfied
# for the real bundle packages. That's a harmless, dedup'd-by-overlay
# no-op at runtime if the base image already has the same file.
arch_packages="$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' "${scratch}/ib/.config")"
[ -n "${arch_packages}" ] || { echo "error: could not determine CONFIG_TARGET_ARCH_PACKAGES from IB .config" >&2; exit 1; }

libc_ipk="$(find "${scratch}/ib/build_dir" -iname 'libc_*.ipk' | head -1)"
[ -n "${libc_ipk}" ] || { echo "error: no libc_*.ipk found under ${scratch}/ib/build_dir" >&2; exit 1; }
cp "${libc_ipk}" "${scratch}/libc.ipk"

# --- 4. Run opkg (offline-root) inside the linux/amd64 builder container ---
mkdir -p "${scratch}/stage/tmp"
docker run --rm --platform linux/amd64 \
    -e ARCH_PACKAGES="${arch_packages}" \
    -e PKGS="${pkgs}" \
    -v "${scratch}":/scratch \
    "${DOCKER_IMAGE}" \
    sh -c '
        set -eu
        OPKG=/scratch/ib/staging_dir/host/bin/opkg
        OPTS="--offline-root /scratch/stage --conf /scratch/repositories.conf --add-arch all:100 --add-arch ${ARCH_PACKAGES}:200 --add-dest root:/"
        $OPKG $OPTS update
        # Bootstrap libc from the ImageBuilder-local .ipk (see step 3);
        # installed by path, so it does not need to resolve through the
        # (feedless) local repo.
        $OPKG $OPTS install /scratch/libc.ipk
        $OPKG $OPTS install ${PKGS}
    '

# --- 5. Merge the staged binaries into the bundle overlay -----------------
mkdir -p "${bdir}/root"
for sub in usr/bin usr/lib lib usr/sbin; do
    if [ -d "${scratch}/stage/${sub}" ]; then
        mkdir -p "${bdir}/root/${sub}"
        cp -a "${scratch}/stage/${sub}/." "${bdir}/root/${sub}/"
    fi
done

echo "bundle ${name}: merged [${pkgs}] into ${bdir}/root"
