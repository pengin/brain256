#!/bin/bash
# 起動に必要なビルド済みバイナリ(U-Boot / BrainLILO / exeopener)を取得し、
# SD の boot パーティションと同じ構造で cache/boot/ へ並べる。
# ソースからのビルドはしない。sh1-sh7 のみ対応。
set -ueo pipefail

PROFILE="${1:-imx28}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="${BUILDBRAIN_RELEASE:-2026-03-25-024518}"
LILO_VER="${BRAINLILO_VERSION:-4.1.0}"
COMMIT="${BUILDBRAIN_COMMIT:-2e954a9b4bae780b30e863128d74003260633a7f}"
CACHE_DIR="${BOOT_CACHE_DIR:-${REPO}/cache}"
DEST="${BOOT_DIR:-${REPO}/cache/boot}"
SUMS="${ARTIFACTS_SHA256:-${REPO}/profiles/${PROFILE}/artifacts.sha256}"
MODELS="${BRAIN_MODELS:-sh3}"

UB_URL_BASE="https://github.com/brain-hackers/buildbrain/releases/download/${RELEASE}"
LILO_URL="https://github.com/brain-hackers/brainlilo/releases/download/${LILO_VER}/brainlilo-${LILO_VER}.zip"
EXEOPENER_URL="https://raw.githubusercontent.com/brain-hackers/buildbrain/${COMMIT}/image/exeopener.exe.gz"

for m in ${MODELS}; do
    case "${m}" in
        sh1|sh2|sh3|sh4|sh5|sh6|sh7) ;;
        *)
            echo "error: この経路は sh1-sh7 のみ対応です (${m} の配布物が揃わない)" >&2
            echo "       buildbrain で自前ビルドすれば作れる可能性はありますが、本リポジトリでは扱いません" >&2
            exit 1;;
    esac
done

[ -f "${SUMS}" ] || { echo "error: ${SUMS} がありません" >&2; exit 1; }
mkdir -p "${CACHE_DIR}"

sha_of() {
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'
}

# $1=URL $2=保存名。キャッシュ済みなら取得を省略し、必ずハッシュを照合する。
fetch_verify() {
    url="$1"; name="$2"; path="${CACHE_DIR}/${name}"
    if [ -f "${path}" ]; then
        echo "Already cached: ${name}"
    else
        echo "Fetching ${url}"
        curl -fL --retry 3 -o "${path}.part" "${url}"
        mv "${path}.part" "${path}"
    fi
    expected=$(awk -v k="${name}" '$2 == k {print $1}' "${SUMS}")
    [ -n "${expected}" ] || { echo "error: ${name} が ${SUMS} にありません" >&2; exit 1; }
    actual=$(sha_of "${path}")
    if [ "${expected}" != "${actual}" ]; then
        echo "error: sha256 mismatch for ${name}" >&2
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        exit 1
    fi
    echo "sha256 OK: ${name}"
}

# 毎回作り直す。前回の実行で別モデルの payload が残っていると、build_image.sh の
# ワイルドカードコピー経由で p1/nk と p1/loader に混入するため。
rm -rf "${DEST}"
mkdir -p "${DEST}/nk" "${DEST}/loader" "${DEST}/lilo"
TMP="${CACHE_DIR}/.boot-unzip"

# U-Boot: zip 内のファイル名は p1 での最終名と同じ。変換は不要。
# u-boot.bin と u-boot.sb は p1 に置かないので持ち込まない。
for m in ${MODELS}; do
    NAME="uboot-${m}-${RELEASE}.zip"
    fetch_verify "${UB_URL_BASE}/${NAME}" "${NAME}"
    rm -rf "${TMP}"; mkdir -p "${TMP}"
    unzip -qo "${CACHE_DIR}/${NAME}" -d "${TMP}"
    NUM="${m#sh}"
    cp "${TMP}/release/gen3_${NUM}.bin" "${DEST}/loader/"
    cp "${TMP}"/release/eds*exe.bin "${DEST}/nk/"
    rm -rf "${TMP}"
    echo "boot (${m}): loader/gen3_${NUM}.bin と nk/ を配置しました"
done

# BrainLILO: zip は BrainLILO/ を挟む。zip 内の AppMain.exe は実体が BrainLILO.exe で、
# p1 では AppMain_.exe になる。p1 の AppMain.exe は下の exeopener である。
NAME="brainlilo-${LILO_VER}.zip"
fetch_verify "${LILO_URL}" "${NAME}"
rm -rf "${TMP}"; mkdir -p "${TMP}"
unzip -qo "${CACHE_DIR}/${NAME}" -d "${TMP}"
cp "${TMP}/BrainLILO/BrainLILO.dll" "${DEST}/lilo/"
cp "${TMP}/BrainLILO/BrainLILODrv.dll" "${DEST}/lilo/"
cp "${TMP}/BrainLILO/AppMain.exe" "${DEST}/lilo/AppMain_.exe"
rm -rf "${TMP}"

# exeopener: p1 の AppMain.exe になる。
fetch_verify "${EXEOPENER_URL}" "exeopener.exe.gz"
gzip -cd "${CACHE_DIR}/exeopener.exe.gz" > "${DEST}/lilo/AppMain.exe"

for f in nk loader lilo/BrainLILO.dll lilo/BrainLILODrv.dll lilo/AppMain_.exe lilo/AppMain.exe; do
    [ -e "${DEST}/${f}" ] || { echo "error: ${DEST}/${f} がありません" >&2; exit 1; }
done
echo "boot: ${DEST} へ配置しました (${MODELS})"
