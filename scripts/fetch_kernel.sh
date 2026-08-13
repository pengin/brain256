#!/bin/bash
# 本リポジトリのリリースからカーネル(zImage)とモデルごとの DTB を取得する。
# カーネルをビルドせずに SD イメージを作るための経路。
#
# 上流 buildbrain のリリースを使わないのは、そちらにコンテナ基盤に必要な
# CONFIG_OVERLAY_FS などが入っておらず brainwrt-ct が動かないため。
# 配布物は scripts/build_kernel.sh が作る(メンテナ専用)。
set -ueo pipefail

PROFILE="${1:-imx28}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="${KERNEL_RELEASE:-kernel-6.1.70-1}"
VERSION="${KERNEL_VERSION:-6.1.70-1}"
CACHE_DIR="${KERNEL_CACHE_DIR:-${REPO}/cache}"
DEST="${KERNEL_DIR:-${REPO}/cache/kernel}"
SUMS="${ARTIFACTS_SHA256:-${REPO}/profiles/${PROFILE}/artifacts.sha256}"
MODELS="${BRAIN_MODELS:-sh3}"

ZIP_NAME="brain256-kernel-${VERSION}.zip"
ZIP="${CACHE_DIR}/${ZIP_NAME}"
URL="https://github.com/pengin/brain256/releases/download/${RELEASE}/${ZIP_NAME}"

[ -f "${SUMS}" ] || { echo "error: ${SUMS} がありません" >&2; exit 1; }
mkdir -p "${CACHE_DIR}"
if [ -f "${ZIP}" ]; then
    echo "Already cached: ${ZIP}"
else
    echo "Fetching ${URL}"
    curl -fL --retry 3 -o "${ZIP}.part" "${URL}"
    mv "${ZIP}.part" "${ZIP}"
fi

EXPECTED=$(awk -v k="${ZIP_NAME}" '$2 == k {print $1}' "${SUMS}")
[ -n "${EXPECTED}" ] || { echo "error: ${ZIP_NAME} が ${SUMS} にありません" >&2; exit 1; }
ACTUAL=$(shasum -a 256 "${ZIP}" 2>/dev/null | awk '{print $1}' || sha256sum "${ZIP}" | awk '{print $1}')
if [ "${EXPECTED}" != "${ACTUAL}" ]; then
    echo "error: sha256 mismatch for ${ZIP_NAME}" >&2
    echo "  expected: ${EXPECTED}" >&2
    echo "  actual:   ${ACTUAL}" >&2
    exit 1
fi
echo "sha256 OK: ${ZIP_NAME}"

# zip は release/ 配下にファイルを持つ。その 1 階層を剥がして DEST へ置く。
TMP="${CACHE_DIR}/.kernel-unzip"
rm -rf "${TMP}" "${DEST}"
mkdir -p "${TMP}"
unzip -qo "${ZIP}" -d "${TMP}"
mkdir -p "${DEST}"
mv "${TMP}/release/"* "${DEST}/"
rm -rf "${TMP}"

[ -f "${DEST}/zImage" ] || { echo "error: ${DEST}/zImage がありません" >&2; exit 1; }
for m in ${MODELS}; do
    [ -f "${DEST}/imx28-pw${m}.dtb" ] \
        || { echo "error: ${DEST}/imx28-pw${m}.dtb がありません" >&2; exit 1; }
done
echo "kernel: ${DEST} へ展開しました (${MODELS})"
