# AGENTS.md

## Purpose

brain256 は、同人誌『SHARP Brain に OpenWrt を入れてコンテナを動かす本』の
付録リポジトリです。SHARP Brain 電子辞書（i.MX28 / ARM926EJ-S / Armv5TEJ /
soft-float / 128MB RAM / SD ブート）向けに、OpenWrt ベースの最小 Linux と、
その上で動く軽量コンテナ基盤 `brainwrt-ct` を提供します。

読者が 1 clone で本の Chapter 2〜5 を再現できることが、このリポジトリの
唯一の目的です。本文に出てこないものは原則として足しません。

## 名前について

- `brain256` — 配布リポジトリの名前
- `brainwrt` — ディストリビューション名 / コマンド名

本文には `brainwrt-ct` や `/etc/init.d/brainwrt-gadget` がそのまま印刷されて
います。**`brainwrt` を `brain256` に一括置換してはいけません。**

## Hard constraints（新しい根拠なしに蒸し返さない）

- Arch Linux ARM は 2022-02 に armv5 を落とし、Manjaro ARM は aarch64 専用で
  停止、Debian は trixie で armel を終了。OpenWrt の mxs ターゲット
  （i.MX23/28、`arm_arm926ej-s` パッケージ）が土台である。
- OpenWrt のリリースは `Makefile` の `OPENWRT_VERSION`（24.10.7 系 / opkg）に
  固定する。apk ベースの main ブランチは対象外。
- rootfs のツリーは Linux ファイルシステム上に置くこと。macOS では Docker の
  named volume（`brainwrt-rootfs`）を使う。APFS の bind mount はデバイス
  ノードと setuid ビットを黙って壊す。
- カーネル、U-Boot、BrainLILO は brain-hackers が公開しているビルド済みの
  配布物を `make fetch-kernel` / `make fetch-boot` で取得する。ソースからは
  ビルドしない。期待ハッシュは `profiles/imx28/artifacts.sha256`。
- 対象モデルは `Makefile` の `BRAIN_MODELS`（既定 `sh3`。手元の実機が
  PW-SH3 のみのため）。

## 検証

- `sh tests/brainwrt-ct/test_*.sh` — 11 本。macOS でそのまま走る
- `cd registry && go test ./...`
- SD イメージの通しビルドには buildbrain 側のカーネルビルドが必要で時間が
  かかる。安請け合いせず、走らせていないなら走らせていないと言うこと。
