#!/bin/sh
# patch_mbr() のバイト単位検証: MBR相当のダミーファイルにセンチネル値を書いておき、
# patch_mbr 実行後、オフセット490-493がリトルエンディアンで期待値になるか確認する。
set -eu
here=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$here/../../profiles/imx28/overlay/etc/init.d/brainwrt-data-grow"

fail=0
root=$(mktemp -d)
disk="$root/fake-disk"
# 512バイトのダミーMBR: 全部0xAA(センチネル)で埋める
dd if=/dev/zero bs=1 count=512 2>/dev/null | LC_ALL=C tr '\0' '\252' > "$disk"

export DISK_DEV="$disk"

# 0x01020304 = 16909060 をパッチ -> リトルエンディアンで 04 03 02 01 になるはず
sh -c ". '$SCRIPT'; patch_mbr 16909060"

# macOS(BSD od)とLinux(GNU od)で `od` の出力フォーマット(端数行のパディング等)が
# 異なるため、テキスト比較ではなく `cmp` でバイト単位に比較する。
printf '\004\003\002\001' > "$root/expected"
dd if="$disk" bs=1 skip=490 count=4 2>/dev/null > "$root/got"
cmp -s "$root/expected" "$root/got" || { echo "FAIL: MBR bytes at 490-493 mismatch"; fail=1; }

# オフセット490の前後(489, 494)はセンチネル(aa)のまま = 余計なバイトを書いていない
printf '\252' > "$root/sentinel"
dd if="$disk" bs=1 skip=489 count=1 2>/dev/null > "$root/before"
dd if="$disk" bs=1 skip=494 count=1 2>/dev/null > "$root/after"
cmp -s "$root/sentinel" "$root/before" || { echo "FAIL: byte 489 clobbered"; fail=1; }
cmp -s "$root/sentinel" "$root/after" || { echo "FAIL: byte 494 clobbered"; fail=1; }

rm -rf "$root"
[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
