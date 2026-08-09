DOCKER_IMAGE=brainwrt-builder
ROOTFS_VOLUME=brainwrt-rootfs
PROFILE?=imx28

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
