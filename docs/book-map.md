# 本文とファイルの対応

同人誌の各節が、このリポジトリのどこに対応するかの一覧です。

## 第 3 章：OS を組む

| 節 | ファイル |
|---|---|
| 3.1 rootfs 借りてくる | `Dockerfile`（ビルド用コンテナ `brainwrt-builder`）, `Makefile`（`docker-build` / `docker-rootfs`）, `scripts/fetch_rootfs.sh`, `scripts/build_rootfs.sh` |
| 3.2 カーネルは自分で用意しない | `scripts/build_rootfs.sh`（kmod 除去）, `scripts/build_image.sh`（zImage/DTB のコピー） |
| 3.3 SD カードにイメージを書き込む | `scripts/build_image.sh`, `Makefile`（`docker-image`）。この時点の説明では p1+p2 の 2 パーティションです。データ用の p3 は 5.2 で追加します |
| 3.4 自作 Linux を起動する | `profiles/imx28/overlay/etc/banner`, `profiles/imx28/overlay/etc/config/system` |
| 3.5 rootfs の自前ビルド | `scripts/fetch_imagebuilder.sh`, `scripts/build_rootfs_imagebuilder.sh` |
| 3.6 7.1MB が 4.1MB へ | `profiles/imx28/packages.txt` |

## 第 4 章：USB デバッグ環境の整備

| 節 | ファイル |
|---|---|
| 4.1 USB ガジェットという機能 | `profiles/imx28/overlay/etc/init.d/brainwrt-gadget` |
| 4.2 ケーブル 1 本で SSH する | `profiles/imx28/overlay/etc/rc.d/S15brainwrt-gadget`, `profiles/imx28/overlay/etc/config/network`, `profiles/imx28/overlay/usr/sbin/brainwrt-usb-mode` |

## 第 5 章：アプリをコンテナ化する

| 節 | ファイル |
|---|---|
| 5.1 rootfs は小さいままがいい | コンテナを使う理由の説明。対応するコードは 5.2 以降 |
| 5.2 コンテナ基盤は意外とシンプル | `profiles/imx28/overlay/usr/sbin/brainwrt-ct`, `docs/brainwrt-ct.md`。p3 を追加する説明もここです。関連ファイルは `scripts/build_image.sh`（p2 を 160MB に固定して残りを p3 へ）、`profiles/imx28/overlay/etc/init.d/brainwrt-data`（p3 を `/data` へマウント）、`profiles/imx28/overlay/etc/init.d/brainwrt-data-grow`（初回起動時に p3 を拡張する、本文では「割愛」と明記されている実装）です |
| 5.3 バンドルを作ろう | `bundles/webcam/Dockerfile`, `scripts/ct.sh`, `scripts/build_bundle.sh` |
| 5.4 バンドルを動かそう！ | `bundles/webcam/manifest.conf`, `bundles/webcam/root/usr/bin/webcam-run`, `profiles/imx28/overlay/etc/init.d/brainwrt-ct` |
| 5.5 バンドルの置き場を作る | `registry/`, `scripts/registry.sh`, `brainwrt-ct pull` |

## 本文には出てこないもの

以下は、紙面の都合で省略した題材や、次の本に回した題材です。動作に必要なため、このリポジトリには含めています。

| ファイル | 何か |
|---|---|
| `profiles/imx28/overlay/usr/sbin/brainwrt-wifi-connect` | USB Wi-Fi ドングルで `wlan0` を WPA2-PSK の AP に接続する |
| `profiles/imx28/overlay/etc/init.d/wpad` | OpenWrt 純正の wpad を無効化するスタブ（wpa_supplicant の二重起動を防ぐ） |
| `profiles/imx28/overlay/usr/share/hostap/common.uc` | `wpa_supplicant.uc` の import を満たす空実装 |
| `profiles/imx28/overlay/usr/share/udhcpc/brainwrt-host.script` | ホストモード時に DHCP の DNS を `/etc/resolv.conf` へ入れる |
| `scripts/fetch_data_grow_ipks.sh` | `brainwrt-data-grow`（5.2 で「割愛」とされた実装）が使う `resize2fs` 一式の取得 |
| `profiles/imx28/tools/kdreset/` | バンドルが tty を KD_GRAPHICS にしたまま終了したときの復帰ツール |
| `profiles/imx28/tools/vtreset/` | バンドルがアクティブ VT を切り替えたまま落ちたときの復帰ツール |

## パーティション構成について

`scripts/build_image.sh` は p1（boot / FAT32） + p2（rootfs / ext4、既定 160 MB） + p3（data / ext4、残り全部）の 3 パーティションを作成します。

本文の 3.3 では p1+p2 の 2 パーティションとして説明し、p3 は 5.2 で「ここに `/data` 用の p3 を足します」として導入する段階的な構成になっています（3.3 にも「5.2 ではデータ用に 3 つ目を足すことになります」と前振りがあります）。3.3 の図が 2 パーティションなのはそのためで、実装との食い違いではありません。
