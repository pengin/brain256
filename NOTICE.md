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

なお、カーネル（linux-brain の `zImage`）、U-Boot、BrainLILO / boot4u、`nkbin_maker` は buildbrain 側でビルドするもので、このリポジトリには含まれません（§4 参照）。

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
- **linux-brain のカーネル（`zImage`）、U-Boot、BrainLILO / boot4u** — 隣接する `buildbrain` 側でビルドします。カーネルには GPL-2.0 が適用されます。
- **`bundles/webcam` が `opkg install` するパッケージ** — `fswebcam`、`uhttpd`、`libgd`、`libjpeg`、`libwebp`、`zlib` ほか。各パッケージのライセンスに従います。
