FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# kpartx/losetup mount the donor SD image's partitions (needs a
# privileged container). libarchive-tools provides bsdtar, which
# preserves the xattrs/device nodes that GNU tar mishandles by default.
# The second group is what the OpenWrt ImageBuilder needs to run.
# The third group is for OpenWrt full-source kernel work (M2): cloning
# openwrt/openwrt and running `make target/linux/prepare` to materialize
# the patched kernel-6.6 tree we port Brain support onto.
# The fourth group is for cross-compiling third-party CMake-based
# libraries (e.g. NCNN, for the M4 on-device inference feasibility
# spike) against the existing arm926ej-s/musl toolchain, and for
# sanity-checking the resulting armv5tej binaries under user-mode QEMU
# emulation before spending real-hardware time on them.
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
