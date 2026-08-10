#!/bin/sh
# brainwrt-ct pull を wget のスタブで検証する。実ネットワーク／実レジストリは使わない。
# 既存 test_lifecycle.sh と同じ PATH スタブ + env var seam の流儀。
set -eu
here=$(cd "$(dirname "$0")" && pwd)
CT="$here/../../profiles/imx28/overlay/usr/sbin/brainwrt-ct"
root=$(mktemp -d)
APPS="$root/apps"; mkdir -p "$APPS"
CGROOT="$root/cg"   # cgroup 無し=常に down 扱い
stub=$(mktemp -d)

fail=0
must() { "$@" || { echo "FAILED: $*"; fail=1; }; }
no()   { if "$@" 2>/dev/null; then echo "SHOULD FAIL: $*"; fail=1; fi; }

ct() { env BRAINWRT_CT_APPS="$APPS" BRAINWRT_CT_CGROOT="$CGROOT" "$CT" "$@"; }

# pull 対象の「本物」バンドル一式（fixture）を tar 化しておく。
fixture_src="$root/fixture-src"; mkdir -p "$fixture_src/root/usr/bin"
printf 'exec="/usr/bin/foo"\nautostart="0"\n' > "$fixture_src/manifest.conf"
echo '#!/bin/sh' > "$fixture_src/root/usr/bin/foo"
chmod +x "$fixture_src/root/usr/bin/foo"
FIXTURE="$root/fixture.tar"
tar -C "$fixture_src" -cf "$FIXTURE" manifest.conf root

# manifest.conf を欠いた不正バンドル（cmd_install がここで die する想定）。
bad_src="$root/bad-src"; mkdir -p "$bad_src/root"
echo 'no manifest here' > "$bad_src/root/placeholder"
BADFIXTURE="$root/badfixture.tar"
tar -C "$bad_src" -cf "$BADFIXTURE" root

export WGET_CALLS_FILE="$root/wget-calls"
export WGET_FIXTURE="$FIXTURE"
export WGET_BADFIXTURE="$BADFIXTURE"
export WGET_MODE=ok
cat > "$stub/wget" << 'EOF'
#!/bin/sh
echo "$*" >> "$WGET_CALLS_FILE"
case "$WGET_MODE" in
  fail) exit 1 ;;
  empty) : > "$2"; exit 0 ;;
  badmanifest) cp "$WGET_BADFIXTURE" "$2"; exit 0 ;;
  garbage) printf 'this is not a tar file, just garbage bytes 0123456789\n' > "$2"; exit 0 ;;
  *) cp "$WGET_FIXTURE" "$2"; exit 0 ;;
esac
EOF
chmod +x "$stub/wget"
PATH="$stub:$PATH"; export PATH

export BRAINWRT_CT_REGISTRY_URL="http://registry.example/api"

echo "--- pull new bundle (default version=latest) ---"
: > "$WGET_CALLS_FILE"
must ct pull foo
[ -f "$APPS/foo/manifest.conf" ] || { echo "pull: manifest missing"; fail=1; }
[ -x "$APPS/foo/root/usr/bin/foo" ] || { echo "pull: payload missing"; fail=1; }
grep -q 'http://registry.example/api/bundles/foo/latest' "$WGET_CALLS_FILE" || { echo "pull: wrong URL for default version"; fail=1; }

echo "--- pull with explicit version ---"
: > "$WGET_CALLS_FILE"
must ct pull foo2 v3
grep -q 'http://registry.example/api/bundles/foo2/v3' "$WGET_CALLS_FILE" || { echo "pull: wrong URL for explicit version"; fail=1; }

echo "--- pull without BRAINWRT_CT_REGISTRY_URL must fail, wget not called ---"
: > "$WGET_CALLS_FILE"
( unset BRAINWRT_CT_REGISTRY_URL; no ct pull baz )
[ -s "$WGET_CALLS_FILE" ] && { echo "pull: wget was called despite missing registry URL"; fail=1; } || true

echo "--- pull when wget fails must not create the bundle ---"
export WGET_MODE=fail
no ct pull qux
[ -e "$APPS/qux" ] && { echo "pull: bundle dir created despite wget failure"; fail=1; } || true
export WGET_MODE=ok

echo "--- pull with empty (0-byte) response must fail ---"
export WGET_MODE=empty
no ct pull qux2
[ -e "$APPS/qux2" ] && { echo "pull: bundle dir created despite empty response"; fail=1; } || true
export WGET_MODE=ok

echo "--- re-pull replaces an existing registration ---"
echo 'CHANGED' > "$fixture_src/root/usr/bin/foo"
tar -C "$fixture_src" -cf "$FIXTURE" manifest.conf root
must ct pull foo
grep -q CHANGED "$APPS/foo/root/usr/bin/foo" || { echo "pull: re-pull did not replace content"; fail=1; }

echo "--- pull replacement with invalid tar (no manifest.conf) must NOT destroy the existing bundle ---"
: > "$WGET_CALLS_FILE"
must ct pull rb                                    # 正常に事前登録
orig_content=$(cat "$APPS/rb/root/usr/bin/foo")
export WGET_MODE=badmanifest
no ct pull rb                                       # 差し替え用の tar が不正 -> 失敗するはず
[ -f "$APPS/rb/manifest.conf" ] || { echo "pull: rollback bug - original manifest.conf lost after failed replace"; fail=1; }
[ -f "$APPS/rb/root/usr/bin/foo" ] || { echo "pull: rollback bug - original payload lost after failed replace"; fail=1; }
now_content=$(cat "$APPS/rb/root/usr/bin/foo" 2>/dev/null || echo MISSING)
[ "$now_content" = "$orig_content" ] || { echo "pull: rollback bug - original payload content changed after failed replace"; fail=1; }
export WGET_MODE=ok

echo "--- pull failure (invalid tar) must not leak the downloaded temp file ---"
tmpdir_test="$root/tmpdir-under-test"; mkdir -p "$tmpdir_test"
: > "$WGET_CALLS_FILE"
export WGET_MODE=badmanifest
( export TMPDIR="$tmpdir_test"; no ct pull rb2 )
leaked=$(find "$tmpdir_test" -name 'brainwrt-ct-pull-*')
[ -z "$leaked" ] || { echo "pull: temp file leak detected: $leaked"; fail=1; }
export WGET_MODE=ok

echo "--- pull with corrupt (non-tar) download must not leave an orphaned staging dir ---"
: > "$WGET_CALLS_FILE"
export WGET_MODE=garbage
no ct pull corrupt1
orphans=$(find "$APPS" -maxdepth 1 -name '.brainwrt-ct-pull-*')
[ -z "$orphans" ] || { echo "pull: orphaned staging dir left behind after extraction failure: $orphans"; fail=1; }
[ -e "$APPS/corrupt1" ] && { echo "pull: corrupt download registered a bundle"; fail=1; } || true
export WGET_MODE=ok

echo "--- pull: old-bundle teardown failure (post-install) must NOT delete the validated staging replacement ---"
if [ "$(id -u)" = "0" ]; then
  echo "SKIP: running as root, cannot rely on permission-based rm -rf failure simulation"
else
  : > "$WGET_CALLS_FILE"
  must ct pull rmfail                                   # 事前に正常登録しておく
  # rmfail ディレクトリ自体から書き込み権限を剥奪する。root 以外では、ディレクトリ
  # 直下のエントリ（manifest.conf など）の unlink にはそのディレクトリ自身への
  # write 権限が要るため、これで後段の `rm -rf "$APPS/rmfail"`（旧バンドル削除）を
  # 確実に失敗させられる。
  chmod 555 "$APPS/rmfail"
  echo 'CHANGED-RMFAIL' > "$fixture_src/root/usr/bin/foo"
  tar -C "$fixture_src" -cf "$FIXTURE" manifest.conf root
  no ct pull rmfail                                     # 旧バンドル rm -rf が失敗 -> pull 全体も失敗するはず
  staging_found=$(find "$APPS" -maxdepth 1 -name '.brainwrt-ct-pull-*' 2>/dev/null)
  [ -n "$staging_found" ] || { echo "pull: BUG - validated staging replacement was deleted after old-bundle teardown failure"; fail=1; }
  chmod 755 "$APPS/rmfail" 2>/dev/null || true
fi
export WGET_MODE=ok

rm -rf "$root" "$stub"
[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
