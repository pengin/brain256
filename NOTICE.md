# NOTICE

このリポジトリのライセンスは [LICENSE](LICENSE)（MIT）です。ただし、このリポジトリには第三者の著作物から派生した部分と、ビルド時に取得される第三者のバイナリが含まれます。内訳は以下のとおりです。

## 1. 自作部分（MIT / Copyright (c) 2026 pengin）

`Makefile`、`Dockerfile`、`scripts/` 以下（`build_image.sh` を除く）、`profiles/imx28/packages.txt`、`profiles/imx28/overlay/` 以下（§3 を除く）、`profiles/imx28/tools/`、`bundles/webcam/`、`registry/`、`tests/`、`docs/`。

## 2. brain-hackers / buildbrain 由来

`scripts/build_image.sh` は、buildbrain の `image/build_image.sh` から派生したものです。

- 派生元: https://github.com/brain-hackers/buildbrain
- Copyright (c) 2020 Takumi Sueda
- ライセンス: MIT

派生元の著作権表示はファイル冒頭に保持しています。

なお、カーネル（linux-brain の `zImage`）、U-Boot、BrainLILO はいずれもビルド済みの配布物を取得して使うもので、このリポジトリには含まれません（§4 参照）。

## 3. OpenWrt のファイルを置き換える / 呼び出すもの

以下のファイルは OpenWrt のコードを含みません。ただし、OpenWrt に同名ファイルが存在することを前提としています。

| ファイル | 内容 |
|---|---|
| `profiles/imx28/overlay/etc/init.d/wpad` | OpenWrt（hostapd-common）の同名 init スクリプトを上書きして無効化するスタブ。中身は空の `start_service()` のみ |
| `profiles/imx28/overlay/usr/share/hostap/common.uc` | `wpa_supplicant.uc` の `import` を満たすためだけの空関数群。関数名は OpenWrt の API に合わせているが実装は空 |
| `profiles/imx28/overlay/usr/share/udhcpc/brainwrt-host.script` | OpenWrt の `/usr/share/udhcpc/default.script` を呼び出すラッパー |

## 4. ビルドすると取得・生成される第三者のバイナリ

これらはリポジトリには含まれず、ビルド時に取得または生成されます。再配布する場合は、それぞれのライセンスに従ってください。

- **OpenWrt 24.10.7** — `make fetch` / `make fetch-ib` が `downloads.openwrt.org` から取得します。生成される `output/rootfs-imx28.tar`、SD イメージ、`bundles/webcam/root/usr/lib/*.so` はこれに由来します。GPL-2.0 など、OpenWrt の各パッケージのライセンスに従います。
- **linux-brain のカーネル（`zImage`）とモデルごとの DTB** — `make fetch-kernel` が
  `pengin/brain256` のリリース（`brain256-kernel-<version>.zip`）から取得します。これは
  本リポジトリが linux-brain をビルドしたものです。
  - ライセンス: **GPL-2.0**
  - 対応するソース: [pengin/linux-brain](https://github.com/pengin/linux-brain) の
    `5ccf14be66a6549f9b779b3f8c38dd9160a7d388`（タグ `brain256-kernel-6.1.70-1`）。
    brain-hackers/linux-brain の fork で、本リポジトリ作者の 5 コミットを重ねたものです。
  - ビルド設定: リリース zip に同梱の `config`
  - ビルド手順: 本リポジトリの `scripts/build_kernel.sh` と `Dockerfile.kernel`
    （`make kernel-release`）
  - 上流 buildbrain のリリースを使わない理由: そちらにはコンテナ基盤に必要な
    `CONFIG_OVERLAY_FS` などが入っておらず、`brainwrt-ct` が動かないためです。
- **モデルごとの U-Boot と `nk.bin`** — `make fetch-boot` が brain-hackers/buildbrain のリリース（`uboot-<model>-<release>.zip`、MIT）から取得します。SD の `loader/` と `nk/` に置かれます。U-Boot 本体には GPL-2.0 が適用されます。
- **BrainLILO** — `make fetch-boot` が brain-hackers/brainlilo のリリース（`brainlilo-4.1.0.zip`、MIT）から取得します。SD の `アプリ/Launch Linux/` に置かれます。
- **`exeopener.exe.gz`** — `make fetch-boot` が brain-hackers/buildbrain（MIT）から取得します。BrainLILO を起動するためのランチャで、SD の `アプリ/Launch Linux/AppMain.exe` になります。
- **`bundles/webcam` が `opkg install` するパッケージ** — `fswebcam`、`uhttpd`、`libgd`、`libjpeg`、`libwebp`、`zlib` ほか。各パッケージのライセンスに従います。
