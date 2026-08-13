DOCKER_IMAGE=brainwrt-builder
ROOTFS_VOLUME=brainwrt-rootfs
PROFILE?=imx28
# U-Boot と BrainLILO を取る buildbrain のリリース。
BUILDBRAIN_RELEASE?=2026-03-25-024518
export BUILDBRAIN_RELEASE
# カーネルは本リポジトリ自身がビルドして配布する。上流のリリースには
# コンテナ基盤に必要な設定が入っておらず brainwrt-ct が動かないため。
KERNEL_RELEASE?=kernel-6.1.70-1
export KERNEL_RELEASE
# docker-dtb は $$PWD を /work へ mount するので cache/ は /work/cache で見える。
# 別の場所の DTB を使う場合は DTB_SRC_DIR を /work 配下のパスで上書きする。
DTB_SRC_DIR?=/work/cache/kernel
# p1=boot(64M)+p2=rootfs(ROOTFS_PART_M、build_image.sh の既定は 160M)+
# p3=data(残り全部)。実機に fdisk 相当のツールがないため、初回ブートでは
# brainwrt-data-grow が MBR を直接書き換え、p3 を実カード容量まで拡張する。
IMG_SIZE_M?=4096
# 起動用 payload を作る Brain のモデル。既定で sh1-sh7 すべてを入れる。
# BrainLILO は実機の型番から loader/gen3_N.bin を選ぶので、全モデルぶんを置いて
# おけば 1 枚の SD をどの機種でも起動できる。増える容量は 7 MB ほどで、64 MB の
# boot パーティションに十分収まる。
# a7200/a7400 は入れられない。この 2 機種の nk は名前が同じ edna3exe.bin で
# 中身が違うため、1 枚の SD に同居できない。
BRAIN_MODELS?=sh1 sh2 sh3 sh4 sh5 sh6 sh7

# OpenWrt のリリースを固定する。更新時は意図的に変更し、実機で再テストする。
export OPENWRT_VERSION?=24.10.7
export OPENWRT_DONOR_PROFILE?=i2se_duckbill

.PHONY: fetch
fetch:
	./scripts/fetch_rootfs.sh

.PHONY: fetch-ib
fetch-ib:
	./scripts/fetch_imagebuilder.sh

.PHONY: fetch-kernel
fetch-kernel:
	BRAIN_MODELS="$(BRAIN_MODELS)" ./scripts/fetch_kernel.sh $(PROFILE)

.PHONY: fetch-boot
fetch-boot:
	BRAIN_MODELS="$(BRAIN_MODELS)" ./scripts/fetch_boot.sh $(PROFILE)

.PHONY: docker-build
docker-build:
	docker build --platform linux/amd64 -t $(DOCKER_IMAGE) -f Dockerfile .

# ここから下はメンテナ専用。読者は実行しない（カーネルは fetch-kernel で取得する）。
KERNEL_DOCKER_IMAGE=brainwrt-kernel-builder
KERNEL_VERSION?=6.1.70-1

.PHONY: kernel-builder
kernel-builder:
	docker build --platform linux/amd64 -t $(KERNEL_DOCKER_IMAGE) -f Dockerfile.kernel .

.PHONY: kernel-release
kernel-release: kernel-builder
	docker run --rm --platform linux/amd64 \
		-e KERNEL_VERSION="$(KERNEL_VERSION)" \
		-v "$$PWD":/work -w /work $(KERNEL_DOCKER_IMAGE) \
		bash -lc "./scripts/build_kernel.sh"

# donor SD イメージから rootfs パーティションを取り出し、OpenWrt のカーネル
# モジュールを削除する（実際には linux-brain のカーネルを使うため）。profile の
# overlay を適用して output/rootfs-$(PROFILE).tar を作る。rootfs のツリーは
# bind mount したリポジトリではなく、必ず named volume に置く。Docker Desktop
# のホスト共有は mknod (EPERM) を拒否し、uid/gid をホストへ保持しない。また、
# 標準の APFS は大文字小文字を区別しない。これらは rootfs を静かに壊す。
#（APFS でも setuid ビットは正常に保持され、問題ではない。）出力 tarball は
# 属性を tar 内に持つため、bind mount 上に置いて安全である。
.PHONY: docker-rootfs
docker-rootfs: docker-volume-rm docker-volume-create docker-loop-clean
	docker run --rm --platform linux/amd64 --privileged \
		-e OPENWRT_VERSION -e OPENWRT_DONOR_PROFILE \
		-v $(ROOTFS_VOLUME):/work/rootfs \
		-v "$$PWD":/work -w /work $(DOCKER_IMAGE) \
		bash -lc "./scripts/build_rootfs.sh $(PROFILE)"

# ImageBuilder 経路。donor イメージを取り出す代わりに、
# profiles/*/packages.txt と FILES= で渡す overlay から rootfs を作る。
.PHONY: docker-rootfs-ib
docker-rootfs-ib: docker-volume-rm docker-volume-create docker-loop-clean
	docker run --rm --platform linux/amd64 --privileged \
		-e OPENWRT_VERSION -e OPENWRT_DONOR_PROFILE \
		-v $(ROOTFS_VOLUME):/work/rootfs \
		-v "$$PWD":/work -w /work $(DOCKER_IMAGE) \
		bash -lc "./scripts/build_rootfs_imagebuilder.sh $(PROFILE)"

# fetch-kernel が取得した DTB へ profiles/$(PROFILE)/dtb-patch.conf の内容を
# 適用し、output/dtb/ へ書き出す。取得元の DTB は書き換えない。
.PHONY: docker-dtb
docker-dtb:
	docker run --rm --platform linux/amd64 \
		-e BRAIN_MODELS="$(BRAIN_MODELS)" \
		-e DTB_SRC_DIR="$(DTB_SRC_DIR)" \
		-v "$$PWD":/work -w /work $(DOCKER_IMAGE) \
		bash -lc "./scripts/patch_dtb.sh $(PROFILE)"

.PHONY: docker-test-dtb
docker-test-dtb:
	docker run --rm --platform linux/amd64 \
		-v "$$PWD":/work -w /work $(DOCKER_IMAGE) \
		bash -lc "sh tests/test_patch_dtb.sh"

# rootfs tarball を output/work/rootfs へ展開し、fetch-kernel と fetch-boot が
# 取得したカーネル・U-Boot・BrainLILO と組み合わせて SD イメージを作る。
# コンパイルは一切行わないので、自前の brainwrt-builder で完結する。
# SD イメージは output/rootfs-$(PROFILE).tar を焼き込む。overlay を直した後に
# rootfs を組み直さず docker-image を回すと、古い rootfs のイメージが黙って
# 出来上がる（実際にやった）。profiles/ のほうが新しければ止める。
.PHONY: check-rootfs-fresh
check-rootfs-fresh:
	@test -f output/rootfs-$(PROFILE).tar || { \
		echo "error: output/rootfs-$(PROFILE).tar がありません -- 先に 'make docker-rootfs-ib'" >&2; \
		exit 1; }
	@stale=$$(find profiles/$(PROFILE) -type f -newer output/rootfs-$(PROFILE).tar -print -quit); \
	if [ -n "$$stale" ]; then \
		echo "error: output/rootfs-$(PROFILE).tar より profiles/$(PROFILE) のほうが新しい" >&2; \
		echo "       (例: $$stale)" >&2; \
		echo "       overlay の変更が反映されていません -- 先に 'make docker-rootfs-ib'" >&2; \
		exit 1; \
	fi

.PHONY: docker-image
docker-image: check-rootfs-fresh docker-dtb docker-loop-clean
	docker run --rm --platform linux/amd64 --privileged \
		-e BRAIN_MODELS="$(BRAIN_MODELS)" \
		-v "$$PWD":/work -w /work $(DOCKER_IMAGE) \
		bash -lc "rm -rf output/work/rootfs && mkdir -p output/work/rootfs && \
			tar -xpf output/rootfs-$(PROFILE).tar -C output/work/rootfs && \
			./scripts/build_image.sh output/work/rootfs sd_wrt.img $(IMG_SIZE_M)"

# loop device は Docker Desktop VM 全体で共有される。kpartx を使うコンテナが
# detach 前に終了すると残り、古い loop が 8 個あるだけで後続のイメージビルドが
# すべて壊れるため、先に掃除する（ビルドを直列実行する場合だけ安全）。
.PHONY: docker-loop-clean
docker-loop-clean:
	docker run --rm --platform linux/amd64 --privileged $(DOCKER_IMAGE) \
		bash -c "dmsetup remove_all 2>/dev/null; losetup -D 2>/dev/null; true"

.PHONY: docker-volume-create
docker-volume-create:
	docker volume create $(ROOTFS_VOLUME)

.PHONY: docker-volume-rm
docker-volume-rm:
	docker volume rm $(ROOTFS_VOLUME) 2>/dev/null || true

.PHONY: clean
clean:
	rm -rf output/*.tar

.PHONY: distclean
distclean: clean docker-volume-rm
	rm -rf cache/*
