#!/usr/bin/env python3
import struct
import sys


if len(sys.argv) != 2:
    raise SystemExit(f"usage: {sys.argv[0]} OUTPUT.BIN")

# A valid MelonSoc boot image containing one `jal x0, 0` instruction.  The
# simulation exits after observing the loader's success message, before this
# instruction is entered.
with open(sys.argv[1], "wb") as output:
    output.write(struct.pack("<4sII", b"MDDR", 4, 0))
    output.write(struct.pack("<I", 0x0000006F))
