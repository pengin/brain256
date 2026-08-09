DOCKER_IMAGE=brainwrt-builder
ROOTFS_VOLUME=brainwrt-rootfs
PROFILE?=imx28
# buildbrain's builder image carries the ARM cross toolchains that
# build_image.sh needs (it rebuilds per-model U-Boot binaries).
BUILDBRAIN_DOCKER_IMAGE=buildbrain-builder:local
BUILDBRAIN?=../buildbrain
# p1=boot(64M)+p2=rootfs(ROOTFS_PART_M, default 160M in build_image.sh)+
# p3=data(残り全部)。オンデバイスに fdisk 相当のツールが無いので、初回ブートで
# p3 を実カード容量まで拡張するのは brainwrt-data-grow が MBR を直接書いて行う。
IMG_SIZE_M?=4096
# Which Brain models to build boot payloads for. Only sh3 by default
# (the device on hand); full set: a7200 a7400 sh1..sh7.
BRAIN_MODELS?=sh3

# Pin the OpenWrt release; bump deliberately and re-test on target.
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

# Extract the rootfs partition from the donor SD image, drop kernel
# modules (our kernel is linux-brain, not OpenWrt's), apply the profile
# overlay, and emit output/rootfs-$(PROFILE).tar. The rootfs tree lives
# in a named volume: macOS bind mounts (APFS) cannot hold device nodes
# or setuid bits, which silently breaks the rootfs.
.PHONY: docker-rootfs
docker-rootfs: docker-volume-rm docker-volume-create docker-loop-clean
	docker run --rm --platform linux/amd64 --privileged \
		-e OPENWRT_VERSION -e OPENWRT_DONOR_PROFILE \
		-v $(ROOTFS_VOLUME):/work/rootfs \
		-v "$$PWD":/work -w /work $(DOCKER_IMAGE) \
		bash -lc "./scripts/build_rootfs.sh $(PROFILE)"

# ImageBuilder flow: build the rootfs from profiles/*/packages.txt with
# the overlay passed via FILES=, instead of extracting the donor image.
.PHONY: docker-rootfs-ib
docker-rootfs-ib: docker-volume-rm docker-volume-create docker-loop-clean
	docker run --rm --platform linux/amd64 --privileged \
		-e OPENWRT_VERSION -e OPENWRT_DONOR_PROFILE \
		-v $(ROOTFS_VOLUME):/work/rootfs \
		-v "$$PWD":/work -w /work $(DOCKER_IMAGE) \
		bash -lc "./scripts/build_rootfs_imagebuilder.sh $(PROFILE)"

# Reuse buildbrain's builder image: stage our rootfs tarball where
# build_image.sh expects a rootfs directory, then let it assemble the SD
# image (per-model U-Boot, nk.bin, partitioning) exactly like Brainux.
# The kernel comes from linux-brain in the buildbrain tree — see 3.2.
.PHONY: docker-image
docker-image: docker-loop-clean
	docker run --rm --platform linux/amd64 --privileged \
		-e BRAIN_MODELS="$(BRAIN_MODELS)" \
		-v "$$PWD/output":/brainwrt-output \
		-v "$$PWD/scripts":/brainwrt-scripts \
		-v "$$(cd $(BUILDBRAIN) && pwd)":/work -w /work $(BUILDBRAIN_DOCKER_IMAGE) \
		bash -lc "rm -rf brainwrt-rootfs && mkdir brainwrt-rootfs && \
			tar -xpf /brainwrt-output/rootfs-$(PROFILE).tar -C brainwrt-rootfs && \
			make -C nkbin_maker clean all && \
			IMG_BUILD_JOBS=1 /brainwrt-scripts/build_image.sh brainwrt-rootfs sd_wrt.img $(IMG_SIZE_M)"

# Loop devices are global to the Docker Desktop VM and leak when a
# kpartx-using container dies before detaching; eight stale loops is
# all it takes to break every later image build. Sweep them first.
# (Safe only because our builds run serially.)
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
