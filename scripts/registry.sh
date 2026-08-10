#!/bin/sh
# registry.sh — brain-registry への push クライアント（母艦 Mac 側）。
# 対応する pull は device 側の `brainwrt-ct pull`
#（profiles/imx28/overlay/usr/sbin/brainwrt-ct）。
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
BUNDLES="$REPO/bundles"

die()  { echo "registry: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

cmd_push() {
  need curl; need tar
  name=${1:?"usage: push <name> [version]"}
  bdir="$BUNDLES/$name"
  [ -f "$bdir/manifest.conf" ] || die "no manifest: $bdir/manifest.conf (run 'ct.sh build $name' first)"
  [ -d "$bdir/root" ] || die "no root/: $bdir/root (run 'ct.sh build $name' first)"
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  tar -C "$bdir" -cf "$tmp" manifest.conf root
  # macOS には sha256sum（GNU coreutils のみ）がないため、BSD/macOS の
  # shasum -a 256 を使う。fetch_rootfs.sh/fetch_imagebuilder.sh と同じフォールバック。
  hash=$(shasum -a 256 "$tmp" 2>/dev/null | awk '{print $1}' || sha256sum "$tmp" | awk '{print $1}')
  version=${2:-"$(date +%Y%m%d_%H%M%S)_$(printf '%s' "$hash" | cut -c1-8)"}
  url="${BRAINWRT_REGISTRY_URL:?"BRAINWRT_REGISTRY_URL not set"}/bundles/$name/$version"
  token="${BRAINWRT_REGISTRY_TOKEN:?"BRAINWRT_REGISTRY_TOKEN not set"}"
  curl -sf -X PUT -H "Authorization: Bearer $token" --data-binary "@$tmp" "$url"
  echo "registry: pushed $name $version -> $url"
}

case "${1:-}" in
  push) shift; cmd_push "$@";;
  *) die "usage: registry.sh push <name> [version]";;
esac
