#!/usr/bin/env python3
import struct
import sys

text_bin, data_bin, out_bin = sys.argv[1], sys.argv[2], sys.argv[3]

with open(text_bin, "rb") as f:
    text = f.read()

with open(data_bin, "rb") as f:
    data = f.read()

header = struct.pack("<4sII", b"MDDR", len(text), len(data))

with open(out_bin, "wb") as f:
    f.write(header)
    f.write(text)
    f.write(data)
