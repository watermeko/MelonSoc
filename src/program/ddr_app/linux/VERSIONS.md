# Linux software versions

| Component | Version | Ownership |
|---|---:|---|
| Buildroot | 2025.02.16 LTS, commit `135af563b9` | `third_party/buildroot` submodule |
| GCC | 13.4.0 | Buildroot internal RV32 toolchain |
| musl | Buildroot 2025.02.16 default | Buildroot internal RV32 toolchain |
| BusyBox | Buildroot 2025.02.16 default | Buildroot target package |
| Linux | 6.6 | Buildroot custom version, pinned hash |
| OpenSBI | 1.7 | Buildroot custom version, pinned hash |

Target tuple and ISA policy:

```text
GNU_TARGET_NAME=riscv32-buildroot-linux-musl
GCC_TARGET_ARCH=rv32imac_zicsr_zifencei
ABI=ilp32
MMU=Sv32
linkage=static
```

Custom source hashes live under `board/melonsoc/patches/`; download hash
checking is mandatory in `configs/melonsoc_defconfig`.
