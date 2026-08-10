#!/bin/sh
# ct.sh — 母艦(Mac)側のコンテナ作成 CLI。
# Docker + QEMU(armv5)で brainwrt-ct バンドルの root/ を組み上げる。
#
#   ct.sh binfmt            qemu-arm を binfmt 登録(一回)
#   ct.sh base [profile]    output/rootfs-<profile>.tar から brainwrt-base:armv5 を生成
#   ct.sh build <name>      bundles/<name>/Dockerfile を build → root/ 抽出 + manifest 生成
#   ct.sh shell <name>      emulated 対話シェルで手動構築 → exit 時に root/ へ捕捉
#
# 既存の scripts/build_bundle.sh（cross offline-root）は温存する。ct.sh は
# postinst 実行・対話探索・ソースビルドが必要な場合の上位路線。
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
CT_PROFILE="${CT_PROFILE:-imx28}"
BASE_IMAGE="${CT_BASE_IMAGE:-brainwrt-base:armv5}"
BUNDLES="$REPO/bundles"

die()  { echo "ct: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

cmd_binfmt() {
  need docker
  echo "ct: registering qemu-arm via binfmt (needs privileged docker)…"
  docker run --privileged --rm tonistiigi/binfmt --install arm
  echo "ct: binfmt ready (arm)"
}

cmd_base() {
  need docker
  profile="${1:-$CT_PROFILE}"
  tar="$REPO/output/rootfs-$profile.tar"
  [ -f "$tar" ] || die "rootfs tar not found: $tar (run 'make docker-rootfs-ib' first)"
  raw="brainwrt-base-raw:$profile"
  echo "ct: importing $tar -> $raw"
  docker import "$tar" "$raw" >/dev/null
  # prep 層: 未ブート rootfs に無い可変ディレクトリを作る(opkg の lock 生成に必要)。
  echo "ct: building $BASE_IMAGE (prep: /var/lock /var/run /tmp)"
  printf 'FROM %s\nRUN mkdir -p /var/lock /var/run /tmp\n' "$raw" \
    | docker build -t "$BASE_IMAGE" - >/dev/null
  docker rmi "$raw" >/dev/null 2>&1 || true
  echo "ct: base image ready -> $BASE_IMAGE"
}

# Dockerfile の LABEL ct.* を読み manifest.conf を生成
gen_manifest() { # gen_manifest <name> <image>
  name=$1; img=$2; mf="$BUNDLES/$name/manifest.conf"
  labels=$(docker inspect -f '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' "$img")
  lget() { printf '%s\n' "$labels" | sed -n "s/^ct\\.$1=//p" | head -1; }
  ex=$(lget exec); [ -n "$ex" ] || die "manifest: Dockerfile に LABEL ct.exec が必要"
  {
    echo "# ct.sh build が Dockerfile の LABEL ct.* から生成 — 手で編集しない"
    echo "exec=\"$ex\""
    v=$(lget mem);       [ -n "$v" ] && echo "mem_max=\"$v\""
    v=$(lget cpu);       [ -n "$v" ] && echo "cpu_max=\"$v\""
    v=$(lget devices);   [ -n "$v" ] && echo "devices=\"$v\""
    v=$(lget seccomp);   [ -n "$v" ] && echo "seccomp=\"$v\""
    v=$(lget hostname);  [ -n "$v" ] && echo "hostname=\"$v\""
    v=$(lget autostart); [ -n "$v" ] && echo "autostart=\"$v\""
    true
  } > "$mf"
}

# build 済みイメージと base の rootfs を書き出し、差分（追加／変更）だけを
# root/ へ抽出する。
extract_delta() { # extract_delta <image> <out-root> [clean=1]
  img=$1; out=$2; clean=${3:-1}
  tmp=$(mktemp -d); built="$tmp/built"; base="$tmp/base"; mkdir -p "$built" "$base"
  # clean=1（build）: root/ を Dockerfile から完全再生成。clean=0（shell）:
  # 既存へ統合する。
  [ "$clean" = 1 ] && rm -rf "$out"
  mkdir -p "$out"
  # import 由来イメージは CMD がなく docker create が拒否するため、プレースホルダー
  # を渡す（コンテナは起動しない）。
  cb=$(docker create "$img" /bin/true);         docker export "$cb"    | tar -C "$built" -xf - ; docker rm "$cb"    >/dev/null
  cbase=$(docker create "$BASE_IMAGE" /bin/true); docker export "$cbase" | tar -C "$base"  -xf - ; docker rm "$cbase" >/dev/null
  # base と同一のファイルを除外（--compare-dest）し、実行時に lower から来る
  # 不要なパスも除外する。
  rsync -a --checksum --compare-dest="$base/" \
    --exclude='/.dockerenv' \
    --exclude='/etc/hostname' --exclude='/etc/resolv.conf' --exclude='/etc/hosts' \
    --exclude='/proc' --exclude='/sys' --exclude='/dev' \
    --exclude='/tmp' --exclude='/var/lock' --exclude='/var/run' \
    --exclude='/var/opkg-lists' --exclude='/usr/lib/opkg' \
    "$built/" "$out/"
  rm -rf "$tmp"
}

cmd_build() {
  need docker; need rsync
  name=${1:?"usage: build <name>"}; bdir="$BUNDLES/$name"
  [ -f "$bdir/Dockerfile" ] || die "no Dockerfile: $bdir/Dockerfile"
  docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || die "base image がありません。'ct.sh base' を先に実行"
  img="brainwrt-bundle-$name"
  echo "ct: docker build -> $img"
  docker build -t "$img" "$bdir" >/dev/null
  echo "ct: extracting delta -> $bdir/root/"
  extract_delta "$img" "$bdir/root"
  gen_manifest "$name" "$img"
  echo "ct: build done -> $bdir/root/ + $bdir/manifest.conf"
}

# 対話コンテナを commit し、差分を root/ へ統合する（build と共通の抽出処理）。
capture_container() { # capture_container <container> <out-root>
  cont=$1; out=$2; img="ctcap-${cont}-$$"
  docker commit "$cont" "$img" >/dev/null
  extract_delta "$img" "$out" 0
  docker rmi "$img" >/dev/null 2>&1 || true
}

cmd_shell() {
  need docker; need rsync
  name=${1:?"usage: shell <name>"}; bdir="$BUNDLES/$name"
  [ -d "$bdir" ] || die "no bundle dir: $bdir (mkdir -p bundles/$name first)"
  docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || die "base image がありません。'ct.sh base' を先に実行"
  cname="ctbuild_$name"
  docker rm -f "$cname" >/dev/null 2>&1 || true
  echo "ct: $BASE_IMAGE の対話シェルに入ります(container=$cname)"
  echo "ct: 例) mkdir -p /var/lock && opkg update && opkg install <pkg>"
  echo "ct: exit で差分を $bdir/root/ へ merge 取り込みします"
  # CT_SHELL_CMD が設定されていれば非対話で実行する（スクリプト化ビルド／テスト用）。
  if [ -n "${CT_SHELL_CMD:-}" ]; then
    docker run --name "$cname" "$BASE_IMAGE" /bin/sh -c "$CT_SHELL_CMD" || true
  else
    docker run -it --name "$cname" "$BASE_IMAGE" /bin/sh || true
  fi
  echo "ct: capturing session delta -> $bdir/root/"
  capture_container "$cname" "$bdir/root"
  docker rm "$cname" >/dev/null 2>&1 || true
  echo "ct: shell capture done. 効いた手順は Dockerfile へ転記を"
}

case "${1:-}" in
  binfmt) cmd_binfmt;;
  base)   shift; cmd_base "$@";;
  build)  shift; cmd_build "$@";;
  shell)  shift; cmd_shell "$@";;
  *) die "usage: ct.sh {binfmt|base [profile]|build <name>|shell <name>}";;
esac
