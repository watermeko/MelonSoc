SHELL := /bin/sh

THIS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_DIR := $(abspath $(THIS_DIR)/../../../..)
BUILDROOT_DIR ?= $(REPO_DIR)/third_party/buildroot
MELONSOC_BUILD_DIR ?= $(abspath $(THIS_DIR)/../../build)
BUILDROOT_OUTPUT ?= $(MELONSOC_BUILD_DIR)/buildroot
BUILDROOT_DL_DIR ?= $(MELONSOC_BUILD_DIR)/downloads/buildroot
BUILDROOT_MAKE = $(MAKE) -C $(BUILDROOT_DIR) \
	O=$(BUILDROOT_OUTPUT) BR2_EXTERNAL=$(THIS_DIR) \
	BR2_DL_DIR=$(BUILDROOT_DL_DIR)

IMAGES_DIR := $(BUILDROOT_OUTPUT)/images
BOOT_BIN := $(MELONSOC_BUILD_DIR)/BOOT.BIN
DDR_PAYLOAD := $(MELONSOC_BUILD_DIR)/linux_payload.bin

.PHONY: all check-buildroot configure sources menuconfig kernel-menuconfig \
	busybox-menuconfig savedefconfig update-kernel-config \
	update-busybox-config legal-info clean

all: check-buildroot configure
	$(BUILDROOT_MAKE)
	cp $(IMAGES_DIR)/BOOT.BIN $(BOOT_BIN)
	cp $(IMAGES_DIR)/linux_payload.bin $(DDR_PAYLOAD)

check-buildroot:
	@test -f $(BUILDROOT_DIR)/Makefile || { \
		echo "error: Buildroot submodule is not initialized" >&2; \
		echo "run: git submodule update --init --recursive" >&2; \
		exit 1; \
	}

configure: check-buildroot
	@if [ ! -f $(BUILDROOT_OUTPUT)/.config ] || \
		[ $(THIS_DIR)/configs/melonsoc_defconfig -nt $(BUILDROOT_OUTPUT)/.config ]; then \
		$(BUILDROOT_MAKE) melonsoc_defconfig; \
	fi

sources: configure
	$(BUILDROOT_MAKE) source

menuconfig: configure
	$(BUILDROOT_MAKE) menuconfig

kernel-menuconfig: configure
	$(BUILDROOT_MAKE) linux-menuconfig

busybox-menuconfig: configure
	$(BUILDROOT_MAKE) busybox-menuconfig

savedefconfig: configure
	$(BUILDROOT_MAKE) savedefconfig

update-kernel-config: configure
	$(BUILDROOT_MAKE) linux-update-defconfig

update-busybox-config: configure
	$(BUILDROOT_MAKE) busybox-update-config

legal-info: configure
	$(BUILDROOT_MAKE) legal-info

clean:
	rm -rf $(BUILDROOT_OUTPUT) $(BOOT_BIN) $(DDR_PAYLOAD)
