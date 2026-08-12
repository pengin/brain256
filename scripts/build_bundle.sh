#!/bin/bash
# バンドルのバイナリ本体を作る。bundles/<name>/packages.txt の内容を
# OpenWrt ImageBuilder の opkg で offline-root のステージング領域へインストールし、
# 生成された usr/bin、usr/lib、lib、usr/sbin を bundles/<name>/root/ へ統合する。
# webcam-run、index.html、manifest.conf などの既存オーバーレイは変更しない
#（opkg が追加するのは usr/ と lib/ 以下だけ）。
#
# ImageBuilder 同梱の opkg（staging_dir/host/bin/opkg）は x86_64 Linux
# バイナリ（同梱の ld-linux-x86-64.so.2 と .opkg.bin を実行するラッパー）で、
# macOS では動かない。そのため opkg の処理は、他の brainwrt ビルドでも使う
# brainwrt-builder に対する `docker run --platform linux/amd64` の中で
# 実行する。このイメージは外部ネットワークに接続でき、opkg が
# downloads.openwrt.org から fswebcam と依存パッケージを取得できることを
# 確認済みである。
#
# キャッシュ済み ImageBuilder の tarball と opkg のステージング root は
# どちらも一時 scratch ディレクトリ（mktemp -d）内で扱い、リポジトリの
# ツリーは直接変更しない。
set -ueo pipefail

name="${1:?usage: build_bundle.sh <name>}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bdir="${REPO_ROOT}/bundles/${name}"
[ -f "${bdir}/packages.txt" ] || { echo "no ${bdir}/packages.txt" >&2; exit 1; }
pkgs="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "${bdir}/packages.txt" | tr '\n' ' ')"
[ -n "${pkgs}" ] || { echo "error: ${bdir}/packages.txt has no packages" >&2; exit 1; }

VERSION="${OPENWRT_VERSION:-24.10.7}"
IB_TAR="${IB_TAR:-${REPO_ROOT}/cache/openwrt-imagebuilder-${VERSION}-mxs-generic.Linux-x86_64.tar.zst}"
[ -f "${IB_TAR}" ] || { echo "error: ${IB_TAR} missing -- run 'make fetch-ib' first" >&2; exit 1; }

DOCKER_IMAGE="${BRAINWRT_DOCKER_IMAGE:-brainwrt-builder}"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/build_bundle.${name}.XXXXXX")"
cleanup() { rm -rf "${scratch}"; }
trap cleanup EXIT

echo "build_bundle: scratch=${scratch}"

# --- 1. キャッシュ済み ImageBuilder を展開 --------------------------------
# tarball は zstd 圧縮されている。コンテナ側の GNU tar
#（1.35、PATH に zstd がない）では展開できないため、zstd/unzstd が使える
# ホスト側（Homebrew）で実行する。
mkdir -p "${scratch}/ib"
zstd -dc "${IB_TAR}" | tar -xf - -C "${scratch}/ib" --strip-components=1

# --- 2. offline-root 用に repositories.conf を調整 -------------------------
# --offline-root 付きで opkg を単独実行（`make image` の外で実行）するための
# 既知の回避策を 2 つ適用する。
#   - 末尾の「option check_signature」を削除する。ImageBuilder の usign
#     信頼ストアを設定せずに offline-root へインストールすると署名検証に
#     失敗するため。これは作業仕様で許容された回避策である。
#   - 「src imagebuilder file:packages」を削除する。このパスは設定ファイル
#     ではなく opkg の cwd 基準で解決され、IB の空の packages/（README では
#     ユーザー追加 .ipk 用のプレースホルダー）を指すため、ここでは実フィード
#     の解決を妨げるだけである。
grep -v -e '^option check_signature' -e '^src imagebuilder' \
    "${scratch}/ib/repositories.conf" > "${scratch}/repositories.conf"

# --- 3. アーキテクチャと ImageBuilder 同梱の libc .ipk を探す --------------
# opkg の依存解決では、ほぼすべての対象パッケージ（fswebcam、libgd など）が
# `Depend: libc` を持つため、「libc」を解決可能にしておく必要がある。しかし、
# このターゲットのリモートフィードには libc が意図的に公開されていない。
# ImageBuilder 自身のツールチェーン用にビルドされた固有パッケージで、
# ImageBuilder の tarball 内 build_dir/ にあらかじめ入っているためである。
# 組み立てられるベース rootfs には libc が既に含まれており、Brain のベース
# イメージ（同じ OpenWrt リリースから donor 抽出）にも存在するので、実行時に
# このバンドルが libc を持つ必要はない。それでも実際のバンドルパッケージの
# 依存解決を成立させるため、まず opkg の offline-root へインストールする。
# 実行時にはオーバーレイで重複排除されるため、同じファイルがベースにあれば
# 実質的に無害な no-op になる。
arch_packages="$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' "${scratch}/ib/.config")"
[ -n "${arch_packages}" ] || { echo "error: could not determine CONFIG_TARGET_ARCH_PACKAGES from IB .config" >&2; exit 1; }

libc_ipk="$(find "${scratch}/ib/build_dir" -iname 'libc_*.ipk' | head -1)"
[ -n "${libc_ipk}" ] || { echo "error: no libc_*.ipk found under ${scratch}/ib/build_dir" >&2; exit 1; }
cp "${libc_ipk}" "${scratch}/libc.ipk"

# --- 4. linux/amd64 ビルダーコンテナ内で opkg（offline-root）を実行 --------
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
        # ImageBuilder 内の .ipk から libc を初期導入する（手順 3 参照）。
        # パスを直接指定してインストールするため、（フィードのない）ローカル
        # リポジトリ経由で解決する必要はない。
        $OPKG $OPTS install /scratch/libc.ipk
        $OPKG $OPTS install ${PKGS}
    '

# --- 5. ステージングしたバイナリをバンドルのオーバーレイへ統合 ------------
mkdir -p "${bdir}/root"
for sub in usr/bin usr/lib lib usr/sbin; do
    if [ -d "${scratch}/stage/${sub}" ]; then
        mkdir -p "${bdir}/root/${sub}"
        cp -a "${scratch}/stage/${sub}/." "${bdir}/root/${sub}/"
    fi
done

echo "bundle ${name}: merged [${pkgs}] into ${bdir}/root"
