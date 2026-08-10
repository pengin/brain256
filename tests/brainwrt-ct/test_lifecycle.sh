#!/bin/sh
# install/remove（バンドル登録・解除）と enable/disable（autostart 切替）を、
# 偽の $APPS を組んで検証する。cgroup／overlay 不要でホスト上で実行できる。
set -eu
here=$(cd "$(dirname "$0")" && pwd)
CT="$here/../../profiles/imx28/overlay/usr/sbin/brainwrt-ct"
root=$(mktemp -d)
APPS="$root/apps"; mkdir -p "$APPS"
CT_ENV_CGROOT="$root/cg"   # cgroup 無し=常に down 扱い
ct() { env BRAINWRT_CT_APPS="$APPS" BRAINWRT_CT_CGROOT="$CT_ENV_CGROOT" "$CT" "$@"; }

# ソースバンドル（ディレクトリ）を用意する。
src="$root/src"; mkdir -p "$src/root/usr/bin"
printf 'exec="/usr/bin/foo"\nautostart="0"\n' > "$src/manifest.conf"
echo '#!/bin/sh' > "$src/root/usr/bin/foo"
chmod +x "$src/root/usr/bin/foo"

fail=0
must() { "$@" || { echo "FAILED: $*"; fail=1; }; }
no()   { if "$@" 2>/dev/null; then echo "SHOULD FAIL: $*"; fail=1; fi; }

echo "--- install from dir ---"
must ct install foo "$src"
[ -f "$APPS/foo/manifest.conf" ] || { echo "install: manifest missing"; fail=1; }
[ -x "$APPS/foo/root/usr/bin/foo" ] || { echo "install: payload missing"; fail=1; }

echo "--- install twice must fail ---"
no ct install foo "$src"

echo "--- bundle names must not escape APPS ---"
no ct install ../escape "$src"

echo "--- manifest is data, not shell code ---"
evil_manifest="$root/evil-manifest"; mkdir -p "$evil_manifest/root"
printf 'exec="/x"\ntouch %s/pwned\n' "$root" > "$evil_manifest/manifest.conf"
must env BRAINWRT_CT_DRYRUN=1 BRAINWRT_CT_APPS="$APPS" BRAINWRT_CT_CGROOT="$CT_ENV_CGROOT" "$CT" install evil-manifest "$evil_manifest"
no env BRAINWRT_CT_DRYRUN=1 BRAINWRT_CT_APPS="$APPS" BRAINWRT_CT_CGROOT="$CT_ENV_CGROOT" "$CT" up evil-manifest
[ ! -e "$root/pwned" ] || { echo "manifest executed shell code"; fail=1; }

echo "--- install bad bundle (no manifest) must fail and not leave dir ---"
bad="$root/bad"; mkdir -p "$bad"; echo x > "$bad/nope"
no ct install bar "$bad"
[ -e "$APPS/bar" ] && { echo "bad install left dir behind"; fail=1; } || true

echo "--- install tar with '..'-traversal member must be rejected, nothing extracted ---"
evil_traversal="$root/evil-traversal.tar"
python3 - "$evil_traversal" <<'PYEOF'
import sys, tarfile, io
path = sys.argv[1]
with tarfile.open(path, "w") as tf:
    data = b'exec="/usr/bin/foo"\nautostart="0"\n'
    ti = tarfile.TarInfo("manifest.conf")
    ti.size = len(data)
    tf.addfile(ti, io.BytesIO(data))
    evil = b"evil"
    ti2 = tarfile.TarInfo("../../evil-outside-marker")
    ti2.size = len(evil)
    tf.addfile(ti2, io.BytesIO(evil))
PYEOF
no ct install evil1 "$evil_traversal"
[ -e "$APPS/evil1" ] && { echo "traversal tar: staging dir left behind after rejection"; fail=1; } || true
[ -e "$root/evil-outside-marker" ] && { echo "traversal tar: member escaped to $root/evil-outside-marker"; fail=1; } || true

echo "--- install tar with absolute-path member must be rejected, nothing extracted ---"
evil_abs="$root/evil-abs.tar"
abs_marker="$root/abs-marker-$$"
python3 - "$evil_abs" "$abs_marker" <<'PYEOF'
import sys, tarfile, io
path, marker = sys.argv[1], sys.argv[2]
with tarfile.open(path, "w") as tf:
    data = b'exec="/usr/bin/foo"\nautostart="0"\n'
    ti = tarfile.TarInfo("manifest.conf")
    ti.size = len(data)
    tf.addfile(ti, io.BytesIO(data))
    evil = b"evil"
    ti2 = tarfile.TarInfo(marker)  # 絶対パスのメンバー名
    ti2.size = len(evil)
    tf.addfile(ti2, io.BytesIO(evil))
PYEOF
no ct install evil2 "$evil_abs"
[ -e "$APPS/evil2" ] && { echo "absolute-path tar: staging dir left behind after rejection"; fail=1; } || true
[ -e "$abs_marker" ] && { echo "absolute-path tar: member escaped to $abs_marker"; fail=1; rm -f "$abs_marker"; } || true

echo "--- enable sets autostart=1 ---"
must ct enable foo
grep -q '^autostart="1"' "$APPS/foo/manifest.conf" || { echo "enable did not set autostart=1"; fail=1; }

echo "--- disable sets autostart=0 ---"
must ct disable foo
grep -q '^autostart="0"' "$APPS/foo/manifest.conf" || { echo "disable did not set autostart=0"; fail=1; }

echo "--- enable when key absent appends it ---"
printf 'exec="/x"\n' > "$APPS/foo/manifest.conf"   # autostart 行なし
must ct enable foo
grep -q '^autostart="1"' "$APPS/foo/manifest.conf" || { echo "enable did not append autostart"; fail=1; }

echo "--- list shows registered foo as down/on ---"
out=$(ct list); echo "$out"
echo "$out" | grep -qE 'foo .*down .*on' || { echo "list row mismatch"; fail=1; }

echo "--- remove deletes registration ---"
must ct remove foo
[ -e "$APPS/foo" ] && { echo "remove left dir"; fail=1; } || true

echo "--- remove non-existent must fail ---"
no ct remove ghost

[ "$fail" = 0 ] && echo PASS || { echo FAIL; exit 1; }
rm -rf "$root"
