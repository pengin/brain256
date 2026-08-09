#!/bin/sh
# Cross-compiles vtreset.c for ARMv5 using the same brainwrt-base:armv5
# Docker image scripts/ct.sh uses for bundle builds, and writes the
# stripped binary straight into the overlay (profiles/imx28/overlay/
# usr/sbin/brainwrt-vtreset is a committed prebuilt binary -- the
# overlay mechanism itself only copies files, it doesn't compile
# anything, so this script must be re-run and its output re-committed
# whenever vtreset.c changes).
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
