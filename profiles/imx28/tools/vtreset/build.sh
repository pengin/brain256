#!/bin/sh
# バンドルビルドで scripts/ct.sh が使うものと同じ brainwrt-base:armv5 Docker
# イメージで vtreset.c を ARMv5 向けにクロスコンパイルし、strip 済みバイナリを
# overlay（profiles/imx28/overlay/usr/sbin/）へ直接書き出す。brainwrt-vtreset は
# コミット済みの prebuilt バイナリであり、overlay の仕組みはファイルをコピーする
# だけでコンパイルしない。そのため vtreset.c を変更したらこのスクリプトを再実行し、
# 出力も再コミットする。
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
out="$repo/profiles/imx28/overlay/usr/sbin/brainwrt-vtreset"

docker run --rm \
  -v "$here":/src -w /src \
  brainwrt-base:armv5 \
  sh -c 'opkg update >/dev/null && opkg install gcc >/dev/null && \
         gcc -O2 -Wall -Wextra -o /tmp/brainwrt-vtreset vtreset.c && \
         strip /tmp/brainwrt-vtreset && \
         cp /tmp/brainwrt-vtreset /src/brainwrt-vtreset'

mv "$here/brainwrt-vtreset" "$out"
chmod +x "$out"
echo "build.sh: wrote $out"
file "$out" 2>/dev/null || true
