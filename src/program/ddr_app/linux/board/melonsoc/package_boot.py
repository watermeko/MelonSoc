#!/usr/bin/env python3
import struct
import sys


FDT_OFFSET = 2 * 1024 * 1024
LINUX_OFFSET = 4 * 1024 * 1024
LOAD_CAPACITY = 0x87000000 - 0x80000000


def main():
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: package_boot.py fw_payload.bin board.dtb BOOT.BIN "
            "ddr_payload.bin"
        )

    payload_path, dtb_path, output_path, ddr_payload_path = sys.argv[1:]
    with open(payload_path, "rb") as source:
        payload = bytearray(source.read())
    with open(dtb_path, "rb") as source:
        dtb = source.read()

    if FDT_OFFSET + len(dtb) > LINUX_OFFSET:
        raise SystemExit("FDT overlaps the Linux payload at +4 MiB")
    if len(payload) <= LINUX_OFFSET:
        raise SystemExit("OpenSBI payload does not contain Linux at +4 MiB")
    if len(payload) > LOAD_CAPACITY:
        raise SystemExit("payload exceeds the MelonSoc DDR boot region")

    payload[FDT_OFFSET:FDT_OFFSET + len(dtb)] = dtb
    header = struct.pack("<4sII", b"MDDR", len(payload), 0)

    with open(output_path, "wb") as output:
        output.write(header)
        output.write(payload)
    with open(ddr_payload_path, "wb") as output:
        output.write(payload)


if __name__ == "__main__":
    main()
