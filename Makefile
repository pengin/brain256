DOCKER_IMAGE=brainwrt-builder
ROOTFS_VOLUME=brainwrt-rootfs
PROFILE?=imx28
# buildbrain のビルダーイメージには build_image.sh が必要とする ARM
# クロスツールチェーンが入っている（モデルごとの U-Boot バイナリを再ビルドする）。
BUILDBRAIN_DOCKER_IMAGE=buildbrain-builder:local
BUILDBRAIN?=../buildbrain
# p1=boot(64M)+p2=rootfs(ROOTFS_PART_M、build_image.sh の既定は 160M)+
# p3=data(残り全部)。実機に fdisk 相当のツールがないため、初回ブートでは
# brainwrt-data-grow が MBR を直接書き換え、p3 を実カード容量まで拡張する。
IMG_SIZE_M?=4096
# 起動用 payload を作る Brain のモデル。既定は手元の実機である sh3 のみ。
# 全モデルは a7200 a7400 sh1..sh7。
BRAIN_MODELS?=sh3

# OpenWrt のリリースを固定する。更新時は意図的に変更し、実機で再テストする。
export OPENWRT_VERSION?=24.10.7
export OPENWRT_DONOR_PROFILE?=i2se_duckbill

.PHONY: fetch
fetch:
	./scripts/fetch_rootfs.sh

.PHONY: fetch-ib
fetch-ib:
	./scripts/fetch_imagebuilder.sh

.PHONY: docker-build
docker-build:
	docker build --platform linux/amd64 -t $(DOCKER_IMAGE) -f Dockerfile .

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

# buildbrain のビルダーイメージを再利用する。build_image.sh が rootfs ディレクトリを
# 探す場所へ rootfs tarball を展開し、Brainux と同じ手順で（モデルごとの U-Boot、
# nk.bin、パーティション分割）SD イメージを組み立てる。
# カーネルは buildbrain ツリー内の linux-brain から取得する（3.2 参照）。
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
docker-image: check-rootfs-fresh docker-loop-clean
	docker run --rm --platform linux/amd64 --privileged \
		-e BRAIN_MODELS="$(BRAIN_MODELS)" \
		-v "$$PWD/output":/brainwrt-output \
		-v "$$PWD/scripts":/brainwrt-scripts \
		-v "$$(cd $(BUILDBRAIN) && pwd)":/work -w /work $(BUILDBRAIN_DOCKER_IMAGE) \
		bash -lc "rm -rf brainwrt-rootfs && mkdir brainwrt-rootfs && \
			tar -xpf /brainwrt-output/rootfs-$(PROFILE).tar -C brainwrt-rootfs && \
			make -C nkbin_maker clean all && \
			IMG_BUILD_JOBS=1 /brainwrt-scripts/build_image.sh brainwrt-rootfs sd_wrt.img $(IMG_SIZE_M)"

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
