# webcam バンドル — 監視カメラ(定期撮影 → uhttpd 配信)。
# ct.sh build webcam で armv5 emulated ビルド → 差分を root/ に抽出 → manifest.conf 生成。
FROM brainwrt-base:armv5

# ドライバ/ミドルウェアを opkg で収集(qemu 上で postinst も実行される)
RUN mkdir -p /var/lock \
    && opkg update \
    && opkg install fswebcam uhttpd

# 手書きの配信スクリプトとページ(バンドルの root/ が単一ソース)
COPY root/usr/bin/webcam-run /usr/bin/webcam-run
COPY root/srv/www/index.html /srv/www/index.html
RUN chmod +x /usr/bin/webcam-run

# manifest.conf の内容(ct.sh build が docker inspect で読み取り生成)
LABEL ct.exec=/usr/bin/webcam-run \
      ct.mem=32M \
      ct.cpu=50% \
      ct.devices=/dev/video0 \
      ct.hostname=webcam \
      ct.seccomp=none \
      ct.autostart=0
