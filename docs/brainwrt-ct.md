# brainwrt-ct — 使い方と仕様

`brainwrt-ct` は、SHARP Brain 向けの OpenWrt 上でアプリをバンドル単位で追加・起動・削除する軽量コンテナ基盤です。基本的な運用は、`install` または `pull` で登録し、`up` で起動し、`list`・`top`・`logs` で状態を確認し、`down` で停止する流れです。

この文書では、デバイス上での操作、バンドルの形式、ホスト側での作成方法、実装上の制約を説明します。SD イメージの作成は [README](../README.md)、本文との対応は [docs/book-map.md](book-map.md)、レジストリの起動と公開は [registry/README.md](../registry/README.md) を参照してください。

## 1. 対象と前提

- 対象モデルは `Makefile` の既定値 `BRAIN_MODELS=sh1 sh2 sh3 sh4 sh5 sh6 sh7`、すなわち PW-SH1 から PW-SH7 です。ただし筆者が実機で確認しているのは PW-SH3 のみです。
- rootfs は OpenWrt 24.10.7 系の `mxs` / `arm_arm926ej-s` をベースにします。パッケージ管理には `opkg` を使います。
- カーネル、U-Boot、BrainLILO は、brain-hackers が公開しているビルド済みの配布物を取得して使います（`make fetch-kernel` / `make fetch-boot`）。このリポジトリでは変更しません。
- デバイス上のバンドルは `/data/apps/<name>/` に置きます。
- `brainwrt-ct` は通常の Docker デーモンではありません。イメージを常駐管理するのではなく、各バンドルのディレクトリを直接起動します。
- 以下の例で `<device>` はデバイスの IP アドレス、`<registry-host>` はレジストリを実行するホスト PC の名前または IP アドレスです。

主な実装ファイルは次のとおりです。

| ファイル | 役割 |
|---|---|
| `profiles/imx28/overlay/usr/sbin/brainwrt-ct` | 操作コマンド本体 |
| `profiles/imx28/overlay/etc/init.d/brainwrt-ct` | `autostart` バンドルの起動と停止 |
| `bundles/webcam/` | 動作確認用のカメラ配信バンドル |
| `scripts/ct.sh` | Docker と QEMU を使うバンドル作成 |
| `scripts/build_bundle.sh` | ImageBuilder を使うオフライン展開 |

## 2. まず動かす

### 2.1 デバイスへ転送済みのバンドルを使う

次の例は、`/tmp/webcam` に `manifest.conf` と `root/` を含むバンドルを転送済みであることを前提にしています。

```sh
# デバイス上
brainwrt-ct install webcam /tmp/webcam
brainwrt-ct up webcam
brainwrt-ct list
brainwrt-ct top
brainwrt-ct logs webcam
brainwrt-ct down webcam
brainwrt-ct remove webcam
```

`remove` は停止済みのバンドルを登録解除します。起動したまま削除する場合は `brainwrt-ct remove webcam --force` と指定します。

### 2.2 レジストリから取得する

レジストリに公開済みのバンドルは、デバイス上で次のように取得します。`pull` は取得したバンドルを検証してから登録し、取得後に自動起動はしません。

```sh
# デバイス上
export BRAINWRT_CT_REGISTRY_URL=http://<registry-host>:8080
brainwrt-ct pull webcam
brainwrt-ct up webcam
```

バージョンを指定する場合は、`brainwrt-ct pull webcam v2` のように実行します。登録済みの同名バンドルがある場合も、新しいバンドルの検証が終わるまでは既存のバンドルを変更しません。

## 3. バンドルの形式

デバイス上のバンドルは `/data/apps/<name>/` に置きます。リポジトリ内では `bundles/<name>/` が同じ形式の作業ディレクトリです。

```text
/data/apps/<name>/
├── manifest.conf   # 起動方法と制限の宣言
├── root/           # ベース rootfs に重ねるファイル
├── work/           # overlayfs の作業領域。up 時に作成
├── merged/         # 実行時のマウント先。up 時に作成
└── log             # 起動プロセスの標準出力と標準エラー
```

`manifest.conf` は必須です。`root/` に置いたファイルはベース rootfs の同じパスに重なり、実行時にアプリが書き込んだ内容もバンドルの `root/` に保存されます。`work/` と `merged/` は運用中に作られるため、配布物には含めません。

## 4. `manifest.conf`

`manifest.conf` はシェルスクリプトとして実行しません。ランチャーが許可したキーの単純な代入だけを読み取るため、未知のキーや不正な値は起動時にエラーになります。`install` は `manifest.conf` の存在だけを確認し、内容の検証は起動時に行います。

```conf
exec="/usr/bin/webcam-run"
mem_max="32M"
cpu_max="50%"
devices="/dev/video0"
seccomp="none"
hostname="webcam"
autostart="0"
```

| キー | 必須 / 既定値 | 内容 |
|---|---|---|
| `exec` | 必須 | コンテナ内で起動する実行ファイル。`up` はこの値をそのまま実行します。 |
| `mem_max` | 省略時は制限なし | `memory.max` の上限。バイト数、`K`、`M`、`G` を指定します。 |
| `cpu_max` | 省略時は制限なし | CPU の上限。`50%` のように割合で指定します。 |
| `devices` | 省略時は指定なし | jail に渡すデバイスを空白区切りで指定します。各値は `ujail -w` に渡されます。 |
| `seccomp` | `default` | `none` または `default` はフィルターなし。それ以外の値は `ujail -S` に渡されます。 |
| `hostname` | バンドル名 | コンテナ内のホスト名です。 |
| `autostart` | `0` | `1` にすると、起動時に自動起動します。 |

`exec` に引数を含めることはできません。引数が必要なアプリは、引数を含むラッパースクリプトを `root/usr/bin/` に置き、そのスクリプトを `exec` に指定します。

バンドル名と `pull` のバージョンには、英数字、`.`、`_`、`-` だけを使います。空文字、`.`、`..` は指定できません。

## 5. コマンドリファレンス

```text
brainwrt-ct up <name>
brainwrt-ct down <name>
brainwrt-ct list
brainwrt-ct top [seconds]
brainwrt-ct logs <name> [lines]
brainwrt-ct enable <name>
brainwrt-ct disable <name>
brainwrt-ct install <name> <directory-or-tar>
brainwrt-ct remove <name> [--force]
brainwrt-ct pull <name> [version]
```

| コマンド | 動作 |
|---|---|
| `up` | overlayfs をマウントし、cgroup を作成してから `ujail` で起動します。 |
| `down` | プロセスを停止し、overlayfs、cgroup、PID ファイルを片付けます。 |
| `list` | 登録済みバンドルの状態、プロセス数、メモリ使用量、CPU 使用量を一覧表示します。 |
| `top` | 起動中バンドルの CPU 使用率とメモリ使用率を表示します。間隔の既定値は 1 秒です。 |
| `logs` | バンドルのログ末尾を表示します。行数の既定値は 20 行です。 |
| `enable` / `disable` | `manifest.conf` の `autostart` を `1` / `0` に変更します。 |
| `install` | ディレクトリまたは tar アーカイブを登録します。`manifest.conf` がないバンドルは拒否します。 |
| `remove` | バンドルを削除します。起動中またはマウントが残っている場合は `--force` が必要です。 |
| `pull` | レジストリから tar アーカイブを取得し、検証して登録します。既定のバージョンは `latest` です。 |

`list` の表示例です。

```text
NAME         STATE AUTO PIDS MEM/LIM         PEAK     CPU(s)  THROTL
webcam       up    off  4    440.0K/32.0M    708.0K   0.4     6/20
```

`THROTL` は CPU 制限によって抑制された回数と監視周期数です。

## 6. 起動・停止と自動後始末

### 6.1 通常のライフサイクル

```text
install / pull
      ↓
登録済みバンドル
      ↓ up
overlayfs と cgroup を準備 → ujail で起動
      ↓
list / top / logs で確認
      ↓ down
プロセス停止 → マウント解除 → cgroup と PID ファイルを削除
```

`down` は `cgroup.kill` が利用できる場合はそれを使い、利用できない場合は cgroup 内のプロセスを個別に停止します。その後、マウント解除と cgroup の削除を行います。コンソールやアクティブな仮想端末を使うバンドルに備え、`brainwrt-kdreset` と `brainwrt-vtreset` も呼び出します。これらのリセットに失敗しても、`down` 自体は失敗させません。

アプリが自分で終了し、`down` が呼ばれない場合に備えて、`up` は後始末用の監視処理を起動します。監視処理は cgroup のプロセス登録を確認してから、cgroup が空になった時点で `down` 相当の処理を実行します。登録を一度も確認できなかった場合は誤った後始末を避けるため何もしません。

### 6.2 自動起動

`/etc/init.d/brainwrt-ct` は、起動時に `/data/apps/*/manifest.conf` を走査し、`autostart="1"` のバンドルを起動します。`enable` と `disable` は設定を変更するだけで、実行中のバンドルを起動・停止しません。変更は次回のブートから反映されます。

### 6.3 `pull` による更新

`pull` は一時ディレクトリへ展開し、`manifest.conf` を含むバンドルとして検証してから既存のバンドルを入れ替えます。取得や検証に失敗した場合は既存のバンドルを残します。入れ替え後の `up` は手動で実行してください。

## 7. 隔離とリソース制限

```text
ホストの /  (読み取り専用の lower)
       +
バンドルの root/  (書き込み可能な upper)
       ↓ overlayfs
merged/  ── ujail -R ── アプリの rootfs
       +
/sys/fs/cgroup/brainwrt-ct/<name>/
       ├── memory.max
       └── cpu.max
```

- `root/` を upper として使うため、ベース rootfs のファイルは直接変更しません。
- `ujail` は UTS、PID、IPC、マウントの名前空間を作ります。ネットワーク名前空間は作らず、ネットワークはホストと共有します。
- `mem_max` は `memory.max`、`cpu_max` は `cpu.max` に反映されます。cgroup v2 の `cpu` と `memory` コントローラーが利用できないカーネルでは制限を設定できません。
- `devices` に指定したデバイスだけを `ujail -w` で渡します。カメラなどを使うバンドルは、必要なデバイスを明示してください。
- `seccomp` に `none` または `default` を指定するとフィルターを付けません。それ以外は指定値を `ujail -S` に渡します。実機向けプロファイルの運用は別途検証が必要です。
- ネットワークは共有されるため、コンテナ内のサービスはデバイスの IP アドレスで待ち受けます。たとえば `bundles/webcam` は `http://<device>:8080/` でアクセスします。ポート番号の衝突は運用側で避けてください。

## 8. カーネル要件

`brainwrt-ct` を動かすカーネルでは、少なくとも次の機能を `=y` で有効にします。

```text
CONFIG_OVERLAY_FS=y
CONFIG_PID_NS=y
CONFIG_UTS_NS=y
CONFIG_IPC_NS=y
CONFIG_MEMCG=y
CONFIG_CGROUP_SCHED=y
CONFIG_FAIR_GROUP_SCHED=y
CONFIG_CFS_BANDWIDTH=y
```

この構成では `USER_NS` と `NET_NS` を使いません。overlayfs はディレクトリで運用するため `SQUASHFS` も必須ではありません。デバイス側では次のコマンドで主要な条件を確認できます。

```sh
grep overlay /proc/filesystems
zcat /proc/config.gz | grep -E "OVERLAY_FS|MEMCG|CGROUP_SCHED|CFS_BANDWIDTH|PID_NS"
mount | grep cgroup2
cat /sys/fs/cgroup/cgroup.controllers
```

最後の出力に `cpu` と `memory` が含まれている必要があります。

## 9. ホスト側でバンドルを作る

### 9.1 Docker と QEMU を使う方法（推奨）

`scripts/ct.sh` は Armv5 の実行環境を QEMU で動かし、Dockerfile の結果からバンドルの `root/` を作ります。ホスト PC に Docker と QEMU の binfmt 設定が必要です。

```sh
scripts/ct.sh binfmt
scripts/ct.sh base
scripts/ct.sh build webcam
scripts/ct.sh shell webcam
```

`base` は `output/rootfs-imx28.tar` から `brainwrt-base:armv5` を作ります。`build` は `bundles/webcam/Dockerfile` をビルドし、ベースとの差分だけを `bundles/webcam/root/` に抽出します。`shell` は対話シェルで試した差分を `root/` に反映します。試した手順は、配布用に Dockerfile へ転記してください。

`bundles/<name>/Dockerfile` の最小例です。

```dockerfile
FROM brainwrt-base:armv5
RUN mkdir -p /var/lock && opkg update && opkg install fswebcam uhttpd
COPY root/usr/bin/webcam-run /usr/bin/webcam-run
COPY root/srv/www/index.html /srv/www/index.html
LABEL ct.exec=/usr/bin/webcam-run ct.mem=32M ct.cpu=50% ct.devices=/dev/video0 ct.hostname=webcam ct.seccomp=none ct.autostart=0
```

`LABEL ct.*` は `manifest.conf` の入力になります。

| Dockerfile のラベル | `manifest.conf` のキー |
|---|---|
| `ct.exec` | `exec` |
| `ct.mem` | `mem_max` |
| `ct.cpu` | `cpu_max` |
| `ct.devices` | `devices` |
| `ct.seccomp` | `seccomp` |
| `ct.hostname` | `hostname` |
| `ct.autostart` | `autostart` |

`CT_PROFILE` はプロファイル（既定 `imx28`）、`CT_BASE_IMAGE` はベースイメージ名（既定 `brainwrt-base:armv5`）を変更します。

### 9.2 ImageBuilder を使う方法

`scripts/build_bundle.sh <name>` は OpenWrt ImageBuilder の `opkg` を `--offline-root` で実行し、`packages.txt` に記載したパッケージと依存関係を `bundles/<name>/root/` に展開します。パッケージの `postinst` は実行しないため、実行時の初期化が必要なアプリはバンドルのスクリプトで行います。対象アーキテクチャは `arm_arm926ej-s_musl_eabi` です。

## 10. レジストリで配布する

ホスト側では、作成した `bundles/<name>/` を隣接する `../brain-registry` のレジストリへ送ります。

```sh
# ホスト PC 上
export BRAINWRT_REGISTRY_URL=http://<registry-host>:8080
export BRAINWRT_REGISTRY_TOKEN=<push-token>
scripts/registry.sh push webcam
scripts/registry.sh push webcam v2
```

デバイス側の取得方法は次のとおりです。

```sh
export BRAINWRT_CT_REGISTRY_URL=http://<registry-host>:8080
brainwrt-ct pull webcam
brainwrt-ct pull webcam v2
```

送信時にアーカイブへ含めるのは `manifest.conf` と `root/` です。Dockerfile や `packages.txt` はデバイスへ送られません。レジストリの起動、ポート、トークンの扱いは [registry/README.md](../registry/README.md) を参照してください。

## 11. 制約とトラブルシュート

- seccomp プロファイルの実機運用は未検証です。`none` または `default` は無フィルターとして扱われます。
- ネットワーク隔離はありません。サービスのポートはデバイス本体と共有されます。
- 実カメラを接続した撮影は未検証です。`bundles/webcam/` は UVC デバイスを `devices` に指定する例です。
- `/data` のマウントは `brainwrt-data` が担当します。SD イメージの構成は [README](../README.md) を参照してください。
- データ領域（p3）を SD カードの実容量まで広げる `brainwrt-data-grow` は、**既定では動きません**。このサービスは MBR を書き換えたあと、新しいパーティションサイズをカーネルに読ませるために自分で再起動します。初回起動の途中で予告なく再起動が起きると故障を疑うことになるため、使う人が明示的に有効化したときだけ動かします。

  ```sh
  /etc/init.d/brainwrt-data-grow enable
  reboot
  ```

  有効化してから拡張が終わるまでに、再起動が 2 回起きます。1 回目は上のコマンドで自分が行うもの、2 回目はサービスが MBR を書き換えた直後に自分で行うものです。2 回目の起動で `resize2fs` が走ります。完了後は `/etc/brainwrt-data-grow.state` が `done` になり、以降は何もしません。経過は `logread | grep brainwrt-data-grow` で追えます。
- 実 SD カードへの書き込みと、実機起動を含む最終確認は未実施です。

cgroup、procfs、sysfs の仮想ファイルは、内容があっても `stat` 上のサイズが 0 になることがあります。状態判定に `[ -s file ]` を使わず、内容を読み取って判定してください。

起動中またはマウントが残ったバンドルを削除する必要がある場合は、通常の `down` を先に試し、それでも残る場合にだけ `remove --force` を使います。ログは `brainwrt-ct logs <name>` で確認できます。

## 12. 開発・テスト用インターフェース

### 環境変数

| 変数 | 既定値 | 用途 |
|---|---|---|
| `BRAINWRT_CT_DRYRUN` | `0` | `1` にすると、mount、`ujail`、cgroup への書き込みを実行せず、実行予定のコマンドを表示します。 |
| `BRAINWRT_CT_APPS` | `/data/apps` | バンドルの置き場を変更します。 |
| `BRAINWRT_CT_CGROOT` | `/sys/fs/cgroup` | cgroup のルートを変更します。テストでは偽のツリーを指定します。 |
| `BRAINWRT_CT_RUN` | `/var/run/brainwrt-ct` | PID ファイルの置き場を変更します。 |
| `BRAINWRT_CT_REGISTRY_URL` | なし | `pull` がアクセスするレジストリのベース URL です。 |
| `BRAINWRT_CT_KDRESET` | `brainwrt-kdreset` | `down` 後に呼ぶコンソールリセットヘルパーを変更します。 |
| `BRAINWRT_CT_VTRESET` | `brainwrt-vtreset` | `down` 後に呼ぶ仮想端末リセットヘルパーを変更します。 |
| `BRAINWRT_CT_REAP_POLL` | `1` | 自動後始末のポーリング間隔を秒で指定します。 |

### テスト

ホスト上で、次の 11 本を実行できます。

```sh
for t in tests/brainwrt-ct/test_*.sh; do
  sh "$t"
done
```

テスト対象は `dryrun`、自動起動、バンドルのライフサイクル、一覧表示、`pull`、後始末、Web カメラ用スクリプト、`/data` のマウントと拡張です。レジストリの Go テストは別に実行します。

```sh
(cd registry && go test ./...)
```
