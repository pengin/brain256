# brainwrt-ct — 軽量コンテナ基盤

`brainwrt-ct` は、OpenWrt の `ujail`(procd)+ overlayfs + cgroup v2 を、
薄い POSIX sh ラッパで束ねた軽量コンテナ基盤である。ベースイメージを最小に
保ったまま、機能を「バンドル」として後付け・隔離実行・クリーン削除できる。

- ランチャ: `profiles/imx28/overlay/usr/sbin/brainwrt-ct`
- 自動起動: `profiles/imx28/overlay/etc/init.d/brainwrt-ct`(procd, START=95)
- バンドル置場: デバイス上 `/data/apps/<name>/`
- PoC バンドル: `bundles/webcam/`(監視カメラ: 定期撮影 → uhttpd 配信)

## 目的(4 つ)

1. **footprint**: ドライバやアプリをベースに詰めず、必要な物だけバンドルで足す。
   (webcam の fswebcam/uhttpd をベースから外し、rootfs 13.84MB→9.16MB, −33.8%)
2. **実行時隔離**: RAM / CPU の上限を cgroup v2 で強制。
3. **クリーンな導入・削除**: バンドル = 1 ディレクトリ。`install`/`remove` で完結。
4. **サンドボックス**: ujail による名前空間隔離(+ 将来 seccomp)。

## アーキテクチャ

```
            ┌─────────────────── デバイス (PW-SH3, kernel 6.1.70) ───────────────────┐
            │                                                                        │
 /data/apps/<name>/                       /sys/fs/cgroup/brainwrt-ct/<name>/         │
   ├─ manifest.conf   ← 宣言              ├─ memory.max   ← RAM 上限                 │
   ├─ root/           ← overlay upper     └─ cpu.max      ← CPU 上限(quota/period)  │
   ├─ work/           ← overlay work                                                 │
   └─ merged/         ← overlay マウント先 = ujail の rootfs                         │
                                                                                     │
   overlay: lowerdir=/ (ro) + upperdir=root/ + workdir=work/  ─┐                     │
                                                               ▼                     │
   ujail -R merged/ -p -h <hostname> [-w <dev>...] -- <exec>                         │
     └ 新規 namespace: UTS / PID / IPC / MNT(NET は共有=ホストと同一)             │
     └ プロセスは起動時に cgroup.procs へ登録され、mem/cpu 上限下で動く            │
            └────────────────────────────────────────────────────────────────────────┘
```

- **FS 方式 = overlay**: ベース `/` を読み取り専用の lower に、バンドルの `root/`
  を upper に重ねる。コンテナ内の書き込みは upper(=バンドル)に閉じ、ベースは汚れない。
  実機で `lowerdir=/` かつ upperdir がその内側(`/data/...`)でも成立することを確認済み。
- **ネットワーク = ホスト共有**(NET_NS を使わない)。コンテナ内でポートを開くと
  ホストの IP でそのまま見える(例: uhttpd `0.0.0.0:8080` → `http://<device>:8080`)。
- **cgroup v2**: `memory.max`(バイト)と `cpu.max`("<quota> <period>", period=100000us)。
  root で `cpu memory` コントローラが委譲されている必要がある(ランチャが best-effort で
  `cgroup.subtree_control` に `+memory +cpu` を書く)。

## カーネル要件(linux-brain `brain_defconfig`)

有効: `OVERLAY_FS`, `PID_NS`, `UTS_NS`, `IPC_NS`, `MEMCG`, `CGROUP_SCHED`,
`FAIR_GROUP_SCHED`, `CFS_BANDWIDTH`(いずれも `=y`)。
**あえて入れない**: `USER_NS` / `NET_NS` / `SQUASHFS`
(コンテナ内 root・ホスト共有ネット・overlay はディレクトリ運用のため)。

デバイス側の確認:
```sh
grep overlay /proc/filesystems
zcat /proc/config.gz | grep -E 'OVERLAY_FS|MEMCG|CGROUP_SCHED|CFS_BANDWIDTH|PID_NS'
mount | grep cgroup2
cat /sys/fs/cgroup/cgroup.controllers   # "cpu memory" が要る
```

## バンドルの構成

`/data/apps/<name>/`(= リポの `bundles/<name>/`):

| パス | 役割 |
|---|---|
| `manifest.conf` | 宣言(sh で source される key=value) |
| `root/` | overlay の **upper**。ベースに重ねたい差分ファイル一式 |
| `work/` | overlay の workdir(実行時に自動生成) |
| `merged/` | overlay マウント先(実行時に自動生成、ujail の rootfs) |

`root/` の例(webcam):
```
root/usr/bin/webcam-run        撮影ループ + uhttpd 起動スクリプト
root/usr/bin/fswebcam          UVC 撮影ツール(バンドル同梱)
root/usr/sbin/uhttpd           Web サーバ(ベースに httpd applet が無いため同梱)
root/usr/lib/*.so              fswebcam/uhttpd の依存ライブラリ
root/srv/www/index.html        配信ページ(<img src="latest.jpg"> を 5s 更新)
```

### manifest.conf のキー

```sh
exec="/usr/bin/webcam-run"   # 必須: コンテナ内で exec するコマンド
mem_max="32M"                # cgroup memory.max(K/M/G。空なら無制限)
cpu_max="50%"                # cgroup cpu.max(% を quota/period=100000 に変換)
devices="/dev/video0"        # ujail -w で jail に渡すデバイス(空白区切り可)
seccomp="none"               # none|default は無フィルタ。他はプロファイルパス(future work)
hostname="webcam"            # jail の UTS ホスト名(既定は <name>)
autostart="0"                # 1 でブート時に自動起動(enable/disable で切替)
```

## コマンドリファレンス

```
brainwrt-ct {up|down|list|top|logs|enable|disable|install|remove|pull} <name> [args]
```

| コマンド | 説明 |
|---|---|
| `up <name>` | overlay マウント → cgroup 作成/上限設定 → `ujail -R merged …` で起動。ログは `<bundle>/log`、PID は `/var/run/brainwrt-ct/<name>.pid` |
| `down <name>` | `cgroup.kill`(無ければ個別 kill)→ merged を umount → cgroup を rmdir → pidfile 削除 |
| `list` | **登録済み全バンドル**を表形式で: `NAME STATE AUTO PIDS MEM/LIM PEAK CPU(s) THROTL` |
| `top [秒]` | 稼働中コンテナの CPU%/MEM% を interval 秒(既定 1)サンプルして 1 回表示 |
| `logs <name> [n]` | `<bundle>/log` の末尾 n 行(既定 20) |
| `enable <name>` | manifest の `autostart` を `1` に(ブート時起動を登録) |
| `disable <name>` | 同 `0` に |
| `install <name> <dir\|tar>` | バンドルを `/data/apps/<name>/` に登録(ディレクトリコピー or tar 展開)。manifest.conf が無ければ拒否 |
| `remove <name> [--force]` | 登録解除。稼働中/overlay 残存時は `--force` が要る(その場合 down してから削除) |
| `pull <name> [version]` | `brain-registry` からバンドル tar を取得し登録。`version` 省略時は `latest`。既に同名バンドルが登録済みなら、新バンドルを別名 staging に検証込みで展開してから既存を down→削除して入れ替える(検証が失敗すれば既存はそのまま残る。入れ替え後は自動 up しない) |

出力例:
```
# brainwrt-ct list
NAME         STATE AUTO PIDS MEM/LIM         PEAK     CPU(s)  THROTL
webcam       up    off  4    440.0K/32.0M    708.0K   0.4     6/20

# brainwrt-ct top
NAME         PIDS MEM/LIM         MEM%   CPU%
webcam       4    440.0K/32.0M    1.3%   0.0%
```
`THROTL` は `nr_throttled/nr_periods`(cpu.max で絞られた回数 / 監視周期数)。

## 自動起動(init.d)

`/etc/init.d/brainwrt-ct`(procd, START=95 / STOP=10)が、起動時に
`/data/apps/*/manifest.conf` を走査し、`autostart="1"` のバンドルを `up` する。
`enable`/`disable` はこのフラグを切り替えるだけなので、次回ブートから反映される。

## バンドルの作り方

### 方法 A(推奨): Docker + QEMU で `scripts/ct.sh`

母艦(Mac)上で armv5 を QEMU エミュレーションし、**本物の Dockerfile** でバンドルの
`root/` を組み上げる。opkg の postinst 実行・ソースビルド・対話探索まで可能。
実装は `scripts/ct.sh` を参照。

```sh
scripts/ct.sh binfmt          # 一回: qemu-arm を binfmt 登録
scripts/ct.sh base            # output/rootfs-imx28.tar -> brainwrt-base:armv5(prep 層込み)
scripts/ct.sh build webcam    # bundles/webcam/Dockerfile を build -> root/ 抽出 + manifest 生成
scripts/ct.sh shell webcam    # emulated 対話シェルで手動構築 -> exit で root/ に merge 取り込み
```

`bundles/<name>/Dockerfile` の例:
```dockerfile
FROM brainwrt-base:armv5
RUN mkdir -p /var/lock && opkg update && opkg install fswebcam uhttpd
COPY root/usr/bin/webcam-run /usr/bin/webcam-run
COPY root/srv/www/index.html /srv/www/index.html
LABEL ct.exec=/usr/bin/webcam-run ct.mem=32M ct.cpu=50% \
      ct.devices=/dev/video0 ct.hostname=webcam ct.seccomp=none ct.autostart=0
```

- **`build`**: `docker build` → built と base の rootfs を書き出し、`rsync --compare-dest` で
  **追加/変更ファイルだけ**を `root/` に再生成(docker 注入ファイル・`/proc|/sys|/dev`・opkg
  lists/メタは除外)。`root/` は毎回まっさらから再生成される。
- **`shell`**: base の対話シェルに入り `opkg install` 等を試し、exit 時に差分を `root/` へ **merge**
  (既存に足す)。効いた手順は Dockerfile に転記する。`CT_SHELL_CMD` を設定すると非対話実行(スクリプト化)。
- **manifest** は Dockerfile の `LABEL ct.*` を単一ソースに生成される(下表)。
  デバイス側 `enable`/`disable` は配備後の manifest を書き換える運用値で、再ビルドで既定に戻る。

| LABEL | manifest | | LABEL | manifest |
|---|---|---|---|---|
| `ct.exec`(必須) | `exec` | | `ct.devices` | `devices` |
| `ct.mem` | `mem_max` | | `ct.hostname` | `hostname` |
| `ct.cpu` | `cpu_max` | | `ct.seccomp` | `seccomp` |
| `ct.autostart` | `autostart` | | | |

環境変数: `CT_PROFILE`(既定 imx28)、`CT_BASE_IMAGE`(既定 brainwrt-base:armv5)。

### 方法 B: `scripts/build_bundle.sh`(cross offline-root)

`scripts/build_bundle.sh <name>` が OpenWrt ImageBuilder の opkg を `--offline-root` で使い、
`packages.txt` のパッケージ(と依存)を `bundles/<name>/root/` に展開する。**実行を伴わない
軽量パッケージング**(postinst は走らない)。ターゲット arch は `arm_arm926ej-s_musl_eabi`。
opkg 本体は x86_64 のため linux/amd64 docker 内で動かす(ネットワーク要、foreground)。

## レジストリでの配布(push/pull)

`ct.sh build` で作った `bundles/<name>/` を、`brain-registry`(sibling repo
`../brain-registry`)経由でデバイスへ配布できる。

母艦(Mac)側で push:
```sh
export BRAINWRT_REGISTRY_URL=http://<registry-host>:8080
export BRAINWRT_REGISTRY_TOKEN=<push-token>
scripts/registry.sh push webcam          # version省略 -> 自動生成(YYYYMMDD_HHMMSS_<hash8>)
scripts/registry.sh push webcam v2       # version明示
```

デバイス側で pull:
```sh
export BRAINWRT_CT_REGISTRY_URL=http://<registry-host>:8080
brainwrt-ct pull webcam                  # version省略 -> latest
brainwrt-ct pull webcam v2               # version明示
```

`pull` は `wget`(`uclient-fetch`、rootfs に既存)で取得し、既存の `install` ロジックへ
橋渡しする。同名バンドルが登録済みなら、まず新バンドルを staging ディレクトリに検証込みで
展開し、それが成功した場合のみ既存を down→削除して入れ替える(検証に失敗した場合は既存の
バンドルはそのまま残る。入れ替え後の `up` は手動)。
push 側の tar 化対象は `manifest.conf` と `root/` のみ(`Dockerfile`/`packages.txt` は含まない)。

## 開発シーム(環境変数)

| 変数 | 既定 | 用途 |
|---|---|---|
| `BRAINWRT_CT_DRYRUN` | `0` | `1` で mount/ujail/cgroup 書込を実行せずエコー(macOS でも回せる) |
| `BRAINWRT_CT_APPS` | `/data/apps` | バンドル置場 |
| `BRAINWRT_CT_CGROOT` | `/sys/fs/cgroup` | cgroup ルート(テスト時は偽ツリーを指す) |
| `BRAINWRT_CT_RUN` | `/var/run/brainwrt-ct` | pidfile 置場 |
| `BRAINWRT_CT_REGISTRY_URL` | (なし、`pull` 使用時は必須) | `brain-registry` のベース URL |
| `BRAINWRT_CT_KDRESET` | `brainwrt-kdreset` | `down` 後に呼ぶコンソールリセットヘルパ(テスト時はスタブを指す) |
| `BRAINWRT_CT_VTRESET` | `brainwrt-vtreset` | `down` 後に呼ぶ VT 復帰ヘルパ(`tty1` へ戻す。テスト時はスタブを指す) |
| `BRAINWRT_CT_REAP_POLL` | `1`(秒) | `up` が自動起動する reaper のポーリング間隔(テストで実秒待ちを避けるため上書き可) |

`down` は cgroup.kill が有ればそれを優先して書き込む(=対象 cgroup の全プロセスへ
捕捉不能な SIGKILL を即時送る)。これは、コンテナ側が `/dev/tty0` を
`KD_GRAPHICS` にしていた場合(fbdev に直接描くバンドル)、
プロセス自身の SIGTERM ハンドラや終了処理が一切
実行されないままコンソールが `KD_GRAPHICS` に固まって戻らなくなることを
意味する。そのため `cmd_down` は cgroup 破棄後に必ず `brainwrt-kdreset`
(`profiles/imx28/tools/kdreset/kdreset.c`、ARMv5 へ事前コンパイル済みの
バイナリを `profiles/imx28/overlay/usr/sbin/` にコミット)を呼び、
`/dev/tty0` を `KD_TEXT` に戻す。どのバンドルが down しても無条件に呼ぶ
(グラフィックスモードに触れていないバンドルには無害な no-op)。失敗して
も `down` 自体は失敗させない(best-effort)。`kdreset.c` を変更した場合は
`profiles/imx28/tools/kdreset/build.sh` を再実行し、生成物を再コミット
すること(overlay の仕組み自体はファイルをコピーするだけでコンパイルは
行わない)。

同様に、コンソールの**アクティブ VT** を切り替えるバンドル(全画面 TUI を出す類:
`/dev/console`/`/dev/tty0` は「今アクティブな VT」のエイリアスに過ぎず、
procd の askconsole ログインシェルは ctty を持たない生の `/dev/console`
読み書きのため、TIOCSCTTY で ctty を奪っても入力を奪えない -- 専用 VT
[`tty2`] に一旦切り替えて入力を隔離する設計。実機検証で判明)向けに、
`cmd_down` は同様に `brainwrt-vtreset`
(`profiles/imx28/tools/vtreset/vtreset.c`)を無条件・best-effort で呼び、
`tty1` に戻す。

**reaper(`cmd_up` が自動起動する後始末)**: バンドル自身のプロセスが
(`down` を経由せず)自分で終了した場合 -- 例えば neovim バンドルで `:q`
しただけの場合 -- 誰も `cmd_down` を呼ばないため、overlay 解除・cgroup
削除・コンソール/VT リセットが一切走らない。これは実機検証で見つかった
ギャップで、`:q` だけでは画面が `tty2` の空白のまま戻らなかった。
`cmd_up` は `reap_on_exit` をバックグラウンドで起動し、対象 cgroup の
`cgroup.procs` をポーリングして「登録を確認 → 空になった」ことを実際に
観測できた場合にのみ `cmd_down` を自動で呼ぶ(起動をそもそも観測できな
かった場合は何もしない -- dry-run/テスト環境での誤動作防止)。明示的な
`ct down` と競合しても安全(`cmd_down` 自体が冪等)。

テスト(`tests/brainwrt-ct/`, ホストの sh で完結):
`test_dryrun.sh` / `test_autostart.sh` / `test_webcam_run.sh` /
`test_list_top.sh` / `test_lifecycle.sh` / `test_pull.sh` /
`test_down_kdreset.sh` / `test_up_reaper.sh`。

## 実機検証済み事項(PW-SH3, kernel 6.1.70)

- overlay: `lowerdir=/` + upperdir がその内側でもマウント成立。
- ujail: **`-R <merged>` が rootfs 指定**(`-P` は pidfile。当初 `-P` を誤用していたバグを修正)。
- 隔離: UTS/PID/IPC/MNT は ns inode がホストと別、NET は共有(設計通り)。
- cgroup: `memory.max`/`cpu.max` が効く(webcam が cpu.max で throttle される様子を確認)。
- 配信: コンテナ内 uhttpd が `0.0.0.0:8080` で待受け、母艦 Mac から `http://<device>:8080/` 取得可。
- ライフサイクル: install/enable/disable/remove、稼働中 remove の拒否まで確認。

## 既知の制約 / future work

- **seccomp は未実装**(`none`/`default` はどちらも無フィルタ扱い。実プロファイルは今後)。
- **NET 隔離なし**(ホスト共有が設計。ポート衝突は運用で回避)。
- **実カメラ撮影は未検証**(UVC カメラ未接続。配信は仮 JPG で確認済み)。
- `/data` は専用パーティション(p3, ext4)化済み(`scripts/build_image.sh`、p1=boot 64M /
  p2=rootfs 固定 `ROOTFS_PART_M`(既定 160M) / p3=data 残り全部)。起動時のマウントは
  `profiles/imx28/overlay/etc/init.d/brainwrt-data`(START=10、`brainwrt-ct` の START=95
  より前)が `/dev/mmcblk1p3` を `/data` へマウントする。
- **オンデバイスでの実カード容量までの自動拡張(resize)を実装済み**
  (`profiles/imx28/overlay/etc/init.d/brainwrt-data-grow`、START=9、`brainwrt-data` の
  START=10 より前)。実機に `fdisk`/`sfdisk`/`parted`/`resize2fs`/`blkid` 等が一切なく
  (busybox にも組み込まれず)、USB gadget サブネットのみでインターネット非経路のため
  opkg でも追加できないと確認した(2026-07-20)ため、**fdisk/sfdisk は使わず** MBR の p3
  セクタ数フィールド(オフセット490、4バイト、リトルエンディアン)だけを `dd` で直接
  パッチし、resize2fs は `scripts/fetch_data_grow_ipks.sh` で取得し
  `usr/share/brainwrt-data-grow/` に同梱した e2fsprogs 一式をオフラインで
  `opkg install` して用意する。状態ファイル(`/etc/brainwrt-data-grow.state`)で
  「未着手→(MBRパッチ→reboot)→patched→(resize2fs)→done」の2段階を管理し、
  **1回失敗したら諦める**(`failed` で以後 no-op、リトライしない)。
  実装は `profiles/imx28/overlay/etc/init.d/brainwrt-data-grow`、同梱する ipk を
  集めるのは `scripts/fetch_data_grow_ipks.sh`。
  **実SDカードへの書き込み・実機起動での最終確認は未実施**(物理カード操作が
  必要なため、ビルドしたイメージのオフライン検証まで完了)。

## トラブルシュート / 教訓

- **cgroup/procfs/sysfs の存在・稼働判定に `[ -s file ]` を使わない。**
  これら仮想ファイルは中身があっても stat サイズ 0 を返すため、常に「空」と誤判定する。
  中身を `read` して判定すること(ランチャ `has_procs` 参照)。ホストの regular-file
  fixture はこの差をマスクするので、状態判定系は必ず実機で確認する。
- `remove` が「稼働中なのに down と誤判定」して生きたバンドルを消す事故は上記が原因だった。
  現在は `ct_up || ct_mounted` で判定し、クラッシュ状態(procs 死・mount 残存)でも
  umount してから削除する。
