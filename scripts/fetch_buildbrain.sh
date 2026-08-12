#!/bin/bash
# buildbrain をピン留めコミットで浅く取得し、brain256 が使うサブモジュールだけを
# 初期化する。linux-brain(巨大)と buildroot/boot4u(未使用)は取得しない。
# カーネルと DTB は scripts/fetch_kernel.sh がリリースから取る。
set -ueo pipefail

DEST="${1:-../buildbrain}"
COMMIT="${BUILDBRAIN_COMMIT:-2e954a9b4bae780b30e863128d74003260633a7f}"
URL="${BUILDBRAIN_URL:-https://github.com/brain-hackers/buildbrain}"
# build_image.sh が使うのはこの 3 つだけ。
SUBMODULES="u-boot-brain nkbin_maker brainlilo"

if [ -e "${DEST}" ]; then
    echo "既にあります: ${DEST}"
    echo "  (完全な clone を持っている場合はそのまま使えます。作り直すには削除してください)"
    exit 0
fi

mkdir -p "${DEST}"
cd "${DEST}"
git init -q
git remote add origin "${URL}"
echo "Fetching ${COMMIT} from ${URL}"
git fetch -q --depth 1 origin "${COMMIT}"
git checkout -q FETCH_HEAD
git submodule update --init --depth 1 ${SUBMODULES}

echo "buildbrain: ${COMMIT} を取得しました"
echo "  取得したサブモジュール: ${SUBMODULES}"
echo "  linux-brain と buildroot は取得していません (カーネルは fetch-kernel が取ります)"
