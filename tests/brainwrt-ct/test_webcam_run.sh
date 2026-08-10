#!/bin/sh
# fswebcam をスタブに差し替え、latest.jpg が atomic に生成されるか検証する。
set -eu
here=$(cd "$(dirname "$0")" && pwd)
RUN="$here/../../bundles/webcam/root/usr/bin/webcam-run"
work=$(mktemp -d)
mkdir -p "$work/srv/www"
cat > "$work/fakefswebcam" <<'EOF'
#!/bin/sh
# 最後の引数（出力パス）に固定内容を書く。
eval out=\${$#}
echo "JPEGDATA" > "$out"
EOF
chmod +x "$work/fakefswebcam"
WEBCAM_WWW="$work/srv/www" WEBCAM_FSWEBCAM="$work/fakefswebcam" \
  WEBCAM_ONESHOT=1 sh "$RUN"
[ -f "$work/srv/www/latest.jpg" ] || { echo "FAIL: latest.jpg missing"; exit 1; }
grep -q JPEGDATA "$work/srv/www/latest.jpg" || { echo "FAIL: content"; exit 1; }
# 半端ファイルが残っていないこと（atomic mv）を確認する。tmp は dot ファイル
#「.latest.$$.tmp」なので、dot ファイルにマッチするグロブで確認する。
ls "$work/srv/www"/.latest.*.tmp 2>/dev/null && { echo "FAIL: leftover tmp"; exit 1; }
echo PASS; rm -rf "$work"
