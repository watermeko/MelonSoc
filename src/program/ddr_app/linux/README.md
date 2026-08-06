# MelonSoc Buildroot Linux

This directory is a Buildroot `br2-external` tree. Buildroot owns the RV32
toolchain, musl, BusyBox root filesystem, Linux, DTB, and OpenSBI build. The
upstream Buildroot tree is the pinned `third_party/buildroot` submodule and is
not modified by MelonSoc board support.

From the repository root, select `CONFIG_DDR_APP_LINUX=y` and run:

```sh
git submodule update --init --recursive
make build
```

For Linux-only development:

```sh
make -C src/program/ddr_app/linux configure
make -C src/program/ddr_app/linux all
make -C src/program/ddr_app/linux menuconfig
make -C src/program/ddr_app/linux kernel-menuconfig
make -C src/program/ddr_app/linux busybox-menuconfig
```

The stable outputs consumed by the existing ROM, SD, and simulation flows are:

```text
src/program/build/BOOT.BIN
src/program/build/linux_payload.bin
```

`BOOT.BIN` has the 12-byte `<4sII>` MDDR header. Its payload layout is fixed:

```text
0x80000000  OpenSBI
0x80200000  DTB
0x80400000  Linux Image with the Buildroot initramfs
```

Buildroot rebuilds Linux after generating the initramfs. Consequently,
`board/melonsoc/post-image.sh` always rebuilds the final OpenSBI payload from
the final `images/Image`; the OpenSBI package output built earlier is not used
as the shipped image.

For a quick ROM/SD/FAT32 regression, use the small smoke payload:

```sh
make simulate SIM_SD_SMOKE=1 SIM_CMD="sdload" \
  SIM_EXPECT="Bootloader: SD image ready (4 bytes)"
```

The simulation SD image defaults to 16 MiB. Override it with
`SIM_SD_IMAGE_SIZE_MIB=<MiB>`; the generated FAT and both Verilator SD backing
memories use the same value.
