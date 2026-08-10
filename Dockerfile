FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# kpartx/losetup で donor SD イメージのパーティションをマウントするため、
# privileged コンテナが必要。libarchive-tools の bsdtar は、標準設定の GNU
# tar が扱いを誤りやすい xattr とデバイスノードを保持する。
# 2 つ目のグループは OpenWrt ImageBuilder の実行に必要。
# 3 つ目のグループは OpenWrt フルソースカーネル作業（M2）用。
# openwrt/openwrt の clone と `make target/linux/prepare` により、Brain 対応を移植
# する patched kernel-6.6 ツリーを作る。
# 4 つ目のグループは、既存の arm926ej-s/musl ツールチェーンに対して
# NCNN などの CMake ベースのサードパーティライブラリをクロスコンパイルし、
# 実機で試す前に user-mode QEMU で armv5tej バイナリを検査するためのもの。
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gzip \
        libarchive-tools \
        kpartx \
        util-linux \
        e2fsprogs \
        rsync \
        build-essential \
        file \
        gawk \
        perl \
        python3 \
        unzip \
        wget \
        xz-utils \
        zstd \
        git \
        bc \
        bison \
        flex \
        libncurses-dev \
        libssl-dev \
        device-tree-compiler \
        cmake \
        qemu-user-static \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
