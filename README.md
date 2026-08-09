brain256
========

SHARP Brain（i.MX28 / ARM926EJ-S / Armv5TEJ / 128MB RAM）に
**OpenWrt ベースの最小 Linux** を入れて、その上で軽量コンテナを動かすための
一式です。同人誌の付録リポジトリで、本の Chapter 2〜5 をこれ 1 つで
再現できるようにしてあります。

> **名前について:** `brain256` はこのリポジトリの名前で、中で動く
> ディストリビューションとコマンドの名前は `brainwrt` です（`brainwrt-ct`、
> `/etc/init.d/brainwrt-gadget` など）。本文の表記に合わせています。

対応表は [docs/book-map.md](docs/book-map.md)、コンテナ基盤のリファレンスは
[docs/brainwrt-ct.md](docs/brainwrt-ct.md) にあります。

前提条件
--------

- **Docker**（macOS なら Docker Desktop）。rootfs の操作は named volume 上で
  行います。APFS の bind mount はデバイスノードと setuid ビットを黙って壊すためです
- **隣に [buildbrain](https://github.com/brain-hackers/buildbrain) を clone**
  しておくこと（既定 `../buildbrain`）。カーネル（linux-brain の zImage）、
  U-Boot、BrainLILO / boot4u、`nkbin_maker` を借ります
- **Go 1.24 以降**（`registry/` をビルドする場合のみ）

実機は PW-SH3 で確認しています。他のモデルで同じことができるかは分かりません。

クイックスタート
----------------

```sh
# 1. ビルダーイメージを作る
make docker-build

# 2. OpenWrt の ImageBuilder を取ってくる（sha256 検証込み）
make fetch-ib

# 3. rootfs を組む -> output/rootfs-imx28.tar
make docker-rootfs-ib

# 4. buildbrain 側のカーネルが未ビルドなら先に:
#    (cd ../buildbrain && make docker-build && make docker-kernel)

# 5. SD イメージを組み立てる -> ../buildbrain/image/sd_wrt.img
make docker-image
```

OpenWrt のバージョンは `Makefile` の `OPENWRT_VERSION`（既定 24.10.7）で
固定しています。対象モデルは `BRAIN_MODELS`（既定 `sh3`）で選びます。

```sh
make docker-image BRAIN_MODELS="sh1 sh2 sh3 sh4 sh5 sh6 sh7 a7200 a7400"
```

ドナーイメージから rootfs を抜く経路（本 3.1）を使う場合は、`make fetch` と
`make docker-rootfs` に読み替えてください。

バンドルを作って配る
--------------------

```sh
# 一度だけ: qemu-arm を binfmt に登録し、ベースイメージを作る
./scripts/ct.sh binfmt
./scripts/ct.sh base

# バンドルを組む -> bundles/webcam/root/ と manifest.conf ができる
./scripts/ct.sh build webcam

# レジストリを立てる（別ホストでも同じマシンでもよい）
cd registry && PUSH_TOKEN=<token> go run .

# 母艦から push
BRAINWRT_REGISTRY_URL=http://<host>:8080 \
BRAINWRT_REGISTRY_TOKEN=<token> \
  ./scripts/registry.sh push webcam

# 実機側で取得して起動
export BRAINWRT_CT_REGISTRY_URL=http://<host>:8080
brainwrt-ct pull webcam      # 取得して登録する（自動では起動しない）
brainwrt-ct up webcam
```

レジストリを使わずに手で配ることもできます。`bundles/webcam/` を tar に固めて
実機へ送り、`brainwrt-ct install webcam <tar>` で登録してください。

テスト
------

```sh
sh tests/brainwrt-ct/test_*.sh     # 11 本。実機もカーネル機能も要らない
cd registry && go test ./...
```

ライセンス
----------

MIT（[LICENSE](LICENSE)）。ただし `scripts/build_image.sh` は buildbrain からの
派生で、ビルド時に OpenWrt や linux-brain のバイナリを取得します。
内訳は [NOTICE.md](NOTICE.md) を参照してください。
