#!/usr/bin/env python3
import sys

boot_bin, image_hex = sys.argv[1], sys.argv[2]
with open(boot_bin, "rb") as f:
    boot = f.read()

sectors = 4096
img = bytearray(sectors * 512)
fat_lba = 32
fat_sectors = 32
data_lba = fat_lba + fat_sectors
root_cluster = 2
file_cluster = 3

b = memoryview(img)[0:512]
b[0:3] = b"\xeb\x58\x90"
b[3:11] = b"MSDOS5.0"
b[11:13] = (512).to_bytes(2, "little")
b[13] = 1
b[14:16] = fat_lba.to_bytes(2, "little")
b[16] = 1
b[21] = 0xF8
b[32:36] = sectors.to_bytes(4, "little")
b[36:40] = fat_sectors.to_bytes(4, "little")
b[44:48] = root_cluster.to_bytes(4, "little")
b[510:512] = b"\x55\xaa"

fat = memoryview(img)[fat_lba * 512:(fat_lba + fat_sectors) * 512]
fat[0:4] = b"\xf8\xff\xff\x0f"
fat[4:8] = b"\xff\xff\xff\x0f"
fat[root_cluster * 4:root_cluster * 4 + 4] = b"\xff\xff\xff\x0f"

clusters = (len(boot) + 511) // 512
for i in range(clusters):
    cl = file_cluster + i
    nxt = 0x0FFFFFFF if i == clusters - 1 else cl + 1
    fat[cl * 4:cl * 4 + 4] = nxt.to_bytes(4, "little")

root = memoryview(img)[data_lba * 512:(data_lba + 1) * 512]
root[0:11] = b"BOOT    BIN"
root[11] = 0x20
root[20:22] = (file_cluster >> 16).to_bytes(2, "little")
root[26:28] = (file_cluster & 0xFFFF).to_bytes(2, "little")
root[28:32] = len(boot).to_bytes(4, "little")

start = (data_lba + (file_cluster - 2)) * 512
img[start:start + len(boot)] = boot

with open(image_hex, "w", newline="\n") as f:
    for i in range(0, len(img), 2):
        f.write(f"{img[i] | (img[i + 1] << 8):04x}\n")
