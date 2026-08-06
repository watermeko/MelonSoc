#!/bin/sh
set -eu

images_dir=$1
board_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
opensbi_src="${BASE_DIR}/build/opensbi-1.7"
opensbi_out="${BASE_DIR}/build/opensbi-final"

cross_compile=
for gcc in "${HOST_DIR}"/bin/riscv32-*-linux-musl-gcc; do
	if [ -x "$gcc" ]; then
		cross_compile=${gcc%gcc}
		break
	fi
done

if [ -z "$cross_compile" ]; then
	echo "error: Buildroot RISC-V toolchain was not found" >&2
	exit 1
fi

rm -rf "$opensbi_out"
make -C "$opensbi_src" O="$opensbi_out" \
	CROSS_COMPILE="$cross_compile" \
	PLATFORM=melonsoc PLATFORM_DIR="$board_dir/opensbi/platform" \
	FW_TEXT_START=0x80000000 \
	FW_FDT_PATH="$images_dir/melonsoc.dtb" \
	FW_PAYLOAD_PATH="$images_dir/Image"

fw_payload="$opensbi_out/platform/melonsoc/firmware/fw_payload.bin"
cp "$fw_payload" "$images_dir/fw_payload.bin"
python3 "$board_dir/package_boot.py" \
	"$fw_payload" "$images_dir/melonsoc.dtb" \
	"$images_dir/BOOT.BIN" "$images_dir/linux_payload.bin"
