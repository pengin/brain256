#!/bin/bash
# buildbrain のリリースからカーネル(zImage)とモデルごとの DTB を取得する。
# カーネルをビルドせずに SD イメージを作るための経路。sh1-sh7 のみ対応。
set -ueo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="${BUILDBRAIN_RELEASE:-2026-03-25-024518}"
EXPECTED="${BUILDBRAIN_KERNEL_SHA256:-da7a8f87c6daf982085c2f7042d874654645a28a6318558d3c6ea0e6a2851f69}"
CACHE_DIR="${KERNEL_CACHE_DIR:-${REPO}/cache}"
DEST="${KERNEL_DIR:-${REPO}/cache/kernel}"
MODELS="${BRAIN_MODELS:-sh3}"

# a7200/a7400 の DTB はリリースに入っていない。黙って欠けたイメージを作らせない。
for m in ${MODELS}; do
    case "${m}" in
        sh1|sh2|sh3|sh4|sh5|sh6|sh7) ;;
        *)
            echo "error: この経路は sh1-sh7 のみ対応です (${m} の DTB はリリースに含まれない)" >&2
            echo "       他機種向けには linux-brain を init して 'make docker-kernel' を実行してください" >&2
            exit 1;;
    esac
done

ZIP_NAME="linux-${RELEASE}.zip"
ZIP="${CACHE_DIR}/${ZIP_NAME}"
URL="https://github.com/brain-hackers/buildbrain/releases/download/${RELEASE}/${ZIP_NAME}"

mkdir -p "${CACHE_DIR}"
if [ -f "${ZIP}" ]; then
    echo "Already cached: ${ZIP}"
else
    echo "Fetching ${URL}"
    curl -fL --retry 3 -o "${ZIP}.part" "${URL}"
    mv "${ZIP}.part" "${ZIP}"
fi

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
