#!/bin/sh
# brainwrt-ct up が、バンドル自身のプロセスが `down` を経由せず自分で終了した
# 場合でも、自動的に cmd_down（overlay 解除・cgroup 削除・kdreset/vtreset）を呼ぶ
# ことを検証する。neovim バンドルの実機検証で
# 判明したギャップ: `:q` だけではコンソール/VT が元に戻らず、明示的な
# `ct down` が別途必要だった問題への修正。
#
# 実 overlay/ujail は使わず、PATH 経由で mount/ujail をスタブする。
# 偽の cgroup.procs はただのファイルなので、実 cgroupfs と違いプロセスが終了しても
# 自動では空にならない。スタブ ujail 自身が「子プロセスの終了を検知したらファイルを
# 空にする」ところまで模擬することで、
# reap_on_exit の待ち合わせループが実際に終了できるようにしている。
set -eu
here=$(cd "$(dirname "$0")" && pwd)
CT="$here/../../profiles/imx28/overlay/usr/sbin/brainwrt-ct"
root=$(mktemp -d)
APPS="$root/apps"; mkdir -p "$APPS"
CGROOT="$root/cg"
stub=$(mktemp -d)

fail=0
must() { "$@" || { echo "FAILED: $*"; fail=1; }; }

# mount: overlay マウントは何もせず成功したことにする
cat > "$stub/mount" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$stub/mount"

# setsid: macOS にはないコマンドなのでスタブする（セッション分離自体は
# このテストの検証対象ではなく、引数をそのまま exec するだけ）。
cat > "$stub/setsid" << 'EOF'
#!/bin/sh
exec "$@"
EOF
chmod +x "$stub/setsid"

# ujail: -R/-p/-h/-w などの jail フラグは無視し、`--` 以降だけそのまま実行する。
# 実行後、FAKE_CGROUP_PROCS を空にして「cgroup からプロセスが消えた」ことを
# 模擬する（実 cgroupfs ならカーネルが自動でやることの代役）。
cat > "$stub/ujail" << 'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    *) shift ;;
  esac
done
"$@"
rc=$?
: > "$FAKE_CGROUP_PROCS"
exit "$rc"
EOF
chmod +x "$stub/ujail"

# 登録するバンドル: 少し生きてから終了するだけのスタブ（"foo" 実行ファイル）。
# 一瞬で終了すると reap_on_exit の最初のポーリングが「起動を観測する」前に
# 終わってしまい得るため、短い生存時間を持たせる。
#
# exec は実ホストの絶対パス（stub 配下）を指す。本来は overlay マウント後の
# merged/usr/bin/foo を ujail が chroot 的に -R で解決する想定だが、このテストの
# ujail スタブは chroot をしない（reap_on_exit の検証だけが目的で、実 jail 分離までは
# 模擬しない）。そのため manifest.conf の usr/bin/foo 相対レイアウト自体は install の
# 検証に留め、実際に起動するパスは stub 側の絶対パスにしている。
foo_bin="$stub/foo-app"
cat > "$foo_bin" << 'EOF'
#!/bin/sh
sleep 1
exit 0
EOF
chmod +x "$foo_bin"

src="$root/src"; mkdir -p "$src/root/usr/bin"
printf 'exec="%s"\nautostart="0"\n' "$foo_bin" > "$src/manifest.conf"
cp "$foo_bin" "$src/root/usr/bin/foo"
chmod +x "$src/root/usr/bin/foo"

export KDRESET_CALLS_FILE="$root/kdreset-calls"
KDRESET_NAME="$stub/fake-kdreset"
cat > "$KDRESET_NAME" << 'EOF'
#!/bin/sh
echo "called" >> "$KDRESET_CALLS_FILE"
EOF
chmod +x "$KDRESET_NAME"

RUNDIR="$root/run"
ct() {
  env PATH="$stub:$PATH" \
      BRAINWRT_CT_APPS="$APPS" BRAINWRT_CT_CGROOT="$CGROOT" \
      BRAINWRT_CT_RUN="$RUNDIR" \
      BRAINWRT_CT_KDRESET="$KDRESET_NAME" BRAINWRT_CT_REAP_POLL=0.2 \
      FAKE_CGROUP_PROCS="$CGROOT/brainwrt-ct/foo/cgroup.procs" \
      "$CT" "$@"
}

echo "--- up starts foo, foo exits on its own, reaper auto-tears-down ---"
must ct install foo "$src"
: > "$KDRESET_CALLS_FILE"
must ct up foo

# reap_on_exit はバックグラウンドなので、後始末が終わるまで少し待つ
#（実装は BRAINWRT_CT_REAP_POLL=0 のポーリング間隔を使うため、実運用の 1 秒間隔を
# テストで実際に待つ必要はない）。
i=0
while [ ! -f "$KDRESET_CALLS_FILE" ] || [ ! -s "$KDRESET_CALLS_FILE" ]; do
  i=$((i + 1))
  [ "$i" -gt 100 ] && break
  sleep 0.1 2>/dev/null || sleep 1
done

# cgroup ディレクトリの rmdir 成功有無は検証しない。実 cgroupfs は cgroup.procs などの
# 擬似ファイルが残っていても rmdir を許すが、このテストの fake cgroup.procs はただの
# 通常ファイルなので rmdir が ENOTEMPTY で失敗し得る（test_down_kdreset.sh も同じ理由で
# 検証していない既存の割り切り）。kdreset が呼ばれたことを、cmd_down が実際に走った
# ことの十分な証拠として扱う。
[ -s "$KDRESET_CALLS_FILE" ] || { echo "reaper never called cmd_down (kdreset not invoked)"; fail=1; }
mount | grep -q "$APPS/foo/merged" && { echo "overlay still mounted after auto-teardown"; fail=1; } || true

echo "--- up + explicit down racing the reaper is still safe (idempotent) ---"
: > "$KDRESET_CALLS_FILE"
must ct up foo
# 明示的な down を（reaper がまだ動いている可能性がある間に）重ねて呼ぶ。
# cmd_down 自体が冪等なので、両方が動いても down 自体は失敗しない。
must ct down foo
i=0
while [ ! -s "$KDRESET_CALLS_FILE" ]; do
  i=$((i + 1))
  [ "$i" -gt 100 ] && break
  sleep 0.1 2>/dev/null || sleep 1
done
[ -s "$KDRESET_CALLS_FILE" ] || { echo "kdreset not called in racing-down scenario"; fail=1; }

[ "$fail" = 0 ] && echo PASS || { echo FAIL; exit 1; }
rm -rf "$root" "$stub"
