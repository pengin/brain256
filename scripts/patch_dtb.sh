#!/bin/bash
# buildbrain がビルドした DTB へ usb-role-switch 等を足し、output/dtb/ へ書き出す。
# buildbrain のツリーは読むだけで書き換えない。
set -ueo pipefail

PROFILE="${1:-imx28}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONF="${REPO}/profiles/${PROFILE}/dtb-patch.conf"
SRC_DIR="${DTB_SRC_DIR:-/buildbrain/linux-brain/arch/arm/boot/dts}"
OUT_DIR="${DTB_OUT_DIR:-${REPO}/output/dtb}"
MODELS="${BRAIN_MODELS:-sh3}"

[ -f "${CONF}" ] || { echo "error: ${CONF} がありません" >&2; exit 1; }
# shellcheck source=/dev/null
. "${CONF}"

mkdir -p "${OUT_DIR}"

for m in ${MODELS}; do
    SRC="${SRC_DIR}/imx28-pw${m}.dtb"
    DST="${OUT_DIR}/imx28-pw${m}.dtb"
    [ -f "${SRC}" ] || { echo "error: ${SRC} がありません" >&2; exit 1; }

    # ノードの存在を先に確かめる。将来 DTB の構造が変わったときに、パッチの
    # 当たっていないイメージが黙って出来上がるのを防ぐ。
    if ! fdtget -p "${SRC}" "${DTB_PATCH_NODE}" >/dev/null 2>&1; then
        echo "error: ${SRC} に ${DTB_PATCH_NODE} がありません" >&2
        exit 1
    fi

    cp "${SRC}" "${DST}"

    for kv in ${DTB_PATCH_STRING_PROPS}; do
        prop="${kv%%=*}"; val="${kv#*=}"
        if [ "$(fdtget "${DST}" "${DTB_PATCH_NODE}" "${prop}" 2>/dev/null)" = "${val}" ]; then
            echo "dtb (pw${m}): ${prop} は既に ${val}"
        else
            fdtput -t s "${DST}" "${DTB_PATCH_NODE}" "${prop}" "${val}"
            echo "dtb (pw${m}): ${prop} = ${val} を設定"
        fi
    done

    for prop in ${DTB_PATCH_BOOL_PROPS}; do
        if fdtget -p "${DST}" "${DTB_PATCH_NODE}" 2>/dev/null | grep -qx "${prop}"; then
            echo "dtb (pw${m}): ${prop} は既にある"
        else
            fdtput "${DST}" "${DTB_PATCH_NODE}" "${prop}"
            echo "dtb (pw${m}): ${prop} を追加"
        fi
    done

    # 書き換えた結果を読み直して検証する
    for kv in ${DTB_PATCH_STRING_PROPS}; do
        prop="${kv%%=*}"; val="${kv#*=}"
        [ "$(fdtget "${DST}" "${DTB_PATCH_NODE}" "${prop}")" = "${val}" ] \
            || { echo "error: ${DST} の ${prop} が ${val} になっていません" >&2; exit 1; }
    done
    for prop in ${DTB_PATCH_BOOL_PROPS}; do
        fdtget -p "${DST}" "${DTB_PATCH_NODE}" | grep -qx "${prop}" \
            || { echo "error: ${DST} に ${prop} がありません" >&2; exit 1; }
    done

    echo "dtb (pw${m}): ${DST} を検証しました"
done
