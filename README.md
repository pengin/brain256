brain256
========

このリポジトリは、SHARP Brain（i.MX28 / ARM926EJ-S / Armv5TEJ / 128MB RAM）へ **OpenWrt ベースの最小 Linux**を導入し、そのルートファイルシステム（rootfs）上で軽量コンテナを動かすための一式です。同人誌「Brainを256倍遊び倒す本」の付録であり、本の第 2〜5 章をこのリポジトリ 1 つで再現できるようにしています。

> **名前について：** `brain256` はこのリポジトリの名前で、中で動くディストリビューションとコマンドの名前は `brainwrt` です（`brainwrt-ct`、`/etc/init.d/brainwrt-gadget` など）。本文の表記に合わせています。

同人誌「Brainを256倍遊び倒す本」とリポジトリ内のコード等の対応表は [docs/book-map.md](docs/book-map.md) に、コンテナ基盤のリファレンスは [docs/brainwrt-ct.md](docs/brainwrt-ct.md) にあります。

コンテナバンドルをホスト PC から実機へ配布するための小さな HTTP レジストリ `brain-registry` も `registry/` に含まれています。ホスト PC からトークン認証付きでバンドルを送信し、実機側の `brainwrt-ct pull` で取得・検証・登録できます。レジストリ単体の起動・運用方法は [registry/README.md](registry/README.md) を参照してください。教材・テスト向けの最小実装で、HTTPS やユーザー認証は備えていないため、信頼できる LAN または VPN 内で使用してください。

この README は、ホスト PC でイメージを作り、実機へ持っていくまでの導入用です。実機上の `brainwrt-ct` のコマンド、コンテナバンドル（以下、バンドル）の形式、制約は [brainwrt-ct リファレンス](docs/brainwrt-ct.md) を参照してください。

**コードとともに、頒布した同人誌の電子版をLLMサービスやコーディングエージェントに読み込ませることを推奨します。**

用意する物
----------------

### ハードウェア

- （必須）SHARP Brain：これがないと始まりません。現在、筆者の手元で動作確認が取れているのはPW-Sx3のみです。
- （必須）4GB以上のMicro SDカード：Brainで起動するOSイメージを焼くために必要です。ご家庭にある一般的なものでOK。最小構成では256MBほどあれば十分ですが、今どきそんな容量のMicro SDカードを準備するのは難しいため、4GB以上としています。
- （必須）ビルド用PC（VM）：Linux か macOSでご用意ください。詳細は以下に記します。
- （任意）OTG＆電源供給機能付きUSBハブ：BrainのUSBポートは電源供給ができないため、USB機器を接続する場合には必須です。イメージを焼いて、Linux端末として操作する分には不要です。

### OS

- サポート対象は macOS または Linux です。多くの場面でDockerを使うため、OSに依存した操作はあまりないとは思います。
- Windows は基本的にサポート対象外で、Windows のネイティブ環境でリポジトリをビルドする手順は用意していません。

### ミドルウェア

- Linux では Docker Engine、macOS では Docker Desktop を使います。`docker run --privileged` と `linux/amd64` コンテナを実行できること、Docker デーモンに接続できる権限が必要です。Docker Compose は使いません。

### ツール

- `rsync` は `scripts/ct.sh build` / `shell` でバンドルを作る場合に必要です。SD イメージの通しビルドだけなら、Docker コンテナ内の `rsync` を使うため、ホスト側へ個別にインストールする必要はありません。
- **Go 1.24 以降**は、`registry/` をビルドする場合だけ必要です。
- `kpartx`、`losetup`、`sfdisk`、`mkfs`、`mount` など、rootfs と SD イメージの作成に使う低レベルツールは Docker コンテナ内に入っています。ホストへ個別に用意する必要はありません。
- 他のリポジトリを複製する必要はありません。カーネル・U-Boot・BrainLILO は、[buildbrain](https://github.com/brain-hackers/buildbrain) と [brainlilo](https://github.com/brain-hackers/brainlilo) が公開しているビルド済みの配布物を `make fetch-kernel` / `make fetch-boot` で取得します（合計 10MB 程度）。

### その他（ネットワーク・ハードウェア）

- **rootfs の保存先**: rootfs のツリーは Linux ファイルシステム上に置きます。macOS では Makefile が作成する Docker の名前付きボリューム `brainwrt-rootfs` を利用します。
- **ネットワーク**: 初回は Docker Hub、OpenWrt のダウンロードサイト、binfmt 用イメージへ接続できる必要があります。ImageBuilder や Docker イメージをキャッシュ済みなら、一部の手順はオフラインでも実行できます。
- **ディスク空き容量**: SD イメージ作成ではデフォルトの設定で 4 GiB のイメージファイルを生成します。Docker イメージと OpenWrt のキャッシュも作るため、これより多くの空き容量が必要です。

クイックスタート
----------------

以下は ImageBuilder を使う経路（本の 3.2）で、既定の対象モデル PW-Sx3 の SD イメージを作る手順です。すべてのコマンドをホスト PC のリポジトリ直下で実行します。

このリポジトリだけで完結します。他のリポジトリを複製する必要はありません。

### 1. 起動用のバイナリを取得する（初回のみ）

カーネル、U-Boot、BrainLILO はいずれもビルドしません。Brainux の開発元が公開しているビルド済みの配布物を取得して使います。SD の boot パーティションに置くものは、これまで Brainux が使ってきた資産そのものです。

```sh
make fetch-kernel
make fetch-boot
```

`fetch-kernel` はカーネルと DTB を、`fetch-boot` は U-Boot と BrainLILO を取得します。どちらも `profiles/imx28/artifacts.sha256` に記録した sha256 と照合します。合計で 10MB 程度です。

> **ハッシュについて**
>
> buildbrain と brainlilo は OpenWrt と違って `sha256sums` を公開していません。`artifacts.sha256` の値は本リポジトリで実測したものです。上流の署名による保証ではなく、配布物が後から差し替えられた場合に検出するためのものです。

> **対応機種について**
>
> この手順が対応するのは PW-SH1 から PW-SH7 です。PW-A7200 / A7400 は、配布物に DTB が含まれないため扱いません。[buildbrain](https://github.com/brain-hackers/buildbrain) でカーネルから自前ビルドすれば作れる可能性はありますが、本リポジトリでは扱いません。

### 2. brain256 のビルダーと OpenWrt ImageBuilder を用意する

brain256 の Docker イメージを作り、固定した OpenWrt 24.10.7 の ImageBuilder をダウンロードします。

```sh
make docker-build
make fetch-ib
```

### 3. rootfs を作る

ImageBuilder に brain256 の設定と overlay を適用し、SD イメージへ書き込む rootfs を作成します。

```sh
make docker-rootfs-ib
# output/rootfs-imx28.tar が生成される
```

### 4. SD イメージを作る

手順 1 で取得したカーネル、U-Boot、BrainLILO と、手順 3 で作った rootfs を組み合わせます。

```sh
make docker-image
# output/sd_wrt.img が生成される
```

`docker-image` はコンパイルを一切行いません。取得済みのバイナリと rootfs を組み合わせるだけです。

準備からイメージ作成までを一括して行う場合は、次の 1 行で実行できます。

```sh
make docker-build fetch-kernel fetch-boot fetch-ib docker-rootfs-ib docker-image
```

主な生成物は次のとおりです。

| 生成物 | 内容 |
|---|---|
| `cache/openwrt-imagebuilder-*.tar.zst` | 固定した OpenWrt ImageBuilder のキャッシュ |
| `output/rootfs-imx28.tar` | Brain 用の overlay を適用した rootfs |
| `cache/kernel/{zImage,imx28-pwsh*.dtb}` | 取得したカーネルと DTB |
| `cache/boot/{nk,loader,lilo}` | 取得した U-Boot と BrainLILO |
| `output/dtb/imx28-pw*.dtb` | usb0 を dual-role にするパッチを当てた DTB |
| `output/sd_wrt.img` | boot / rootfs / data の 3 パーティションを持つ SD イメージ |

`make docker-image` は `make docker-dtb` を先に実行し、取得した DTB へ `dr_mode = "otg"` と `usb-role-switch` を追加します。この 2 つがないと、共通の `imx28-brain.dtsi` が usb0 を host に固定したままになり、実機の `brainwrt-usb-mode` が `/sys/class/usb_role` を見つけられません。カーネルは再ビルドしません。

OpenWrt のバージョンは `Makefile` の `OPENWRT_VERSION`（既定 24.10.7）で固定しています。対象モデルは `BRAIN_MODELS`（既定 `sh3`）で選びます。

```sh
make docker-image BRAIN_MODELS="sh1 sh2 sh3 sh4 sh5 sh6 sh7"
```

ドナーイメージから rootfs を取り出す経路（本 3.1）を使う場合は、`make fetch` と `make docker-rootfs` に読み替えてください。

コンテナバンドルを作って配布する
--------------------------------

以下の `scripts/ct.sh` と `scripts/registry.sh` はホスト PC で、`brainwrt-ct` は実機で実行します。

```sh
# 一度だけ: qemu-arm を binfmt に登録し、ベースイメージを作る
./scripts/ct.sh binfmt
./scripts/ct.sh base

# バンドルを組み立てると bundles/webcam/root/ と manifest.conf が生成される
./scripts/ct.sh build webcam

# レジストリを起動する（別ホストでも同じホスト PC でもよい）
cd registry && PUSH_TOKEN=<token> go run .

# ホスト PC から送信
BRAINWRT_REGISTRY_URL=http://<host>:8080 \
BRAINWRT_REGISTRY_TOKEN=<token> \
  ./scripts/registry.sh push webcam

# 実機側で取得して起動する
export BRAINWRT_CT_REGISTRY_URL=http://<host>:8080
brainwrt-ct pull webcam      # 取得して登録する（自動では起動しない）
brainwrt-ct up webcam
```

レジストリを使わず、手動で配布することもできます。`bundles/webcam/` を tar アーカイブにまとめて実機へ送り、`brainwrt-ct install webcam <tar>` で登録してください。

テスト
------

rootfs や実機を用意せず、ホスト PC の POSIX sh だけでコンテナ基盤を確認できます。

```sh
sh tests/brainwrt-ct/test_*.sh     # 11 本。実機もカーネル機能も必要としない
cd registry && go test ./...
```

ライセンス
----------

MIT（[LICENSE](LICENSE)）。ただし `scripts/build_image.sh` は buildbrain からの派生で、ビルド時に OpenWrt や linux-brain のバイナリを取得します。内訳は [NOTICE.md](NOTICE.md) を参照してください。
