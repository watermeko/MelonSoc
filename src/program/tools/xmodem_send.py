#!/usr/bin/env python3
"""Send a MelonSoC BOOT.BIN using XMODEM-CRC."""

import argparse
import sys
import time
from pathlib import Path

import serial


SOH = 0x01
EOT = 0x04
ACK = 0x06
NAK = 0x15
CAN = 0x18
CRC_REQUEST = ord("C")
BLOCK_SIZE = 128


def crc16_ccitt(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def read_byte(port: serial.Serial, deadline: float) -> int:
    while time.monotonic() < deadline:
        value = port.read(1)
        if value:
            return value[0]
    raise TimeoutError("timed out waiting for target")


def wait_for_crc_request(port: serial.Serial, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = port.read(1)
        if value and value[0] == CRC_REQUEST:
            return
    raise TimeoutError("timed out waiting for XMODEM CRC request")


def send_block(port: serial.Serial, block_no: int, data: bytes,
               timeout: float, retries: int) -> None:
    if len(data) != BLOCK_SIZE:
        raise ValueError("XMODEM block must be exactly 128 bytes")

    frame = bytes((SOH, block_no, 0xFF - block_no)) + data
    crc = crc16_ccitt(data)
    frame += bytes((crc >> 8, crc & 0xFF))

    for attempt in range(1, retries + 1):
        port.write(frame)
        try:
            response = read_byte(port, time.monotonic() + timeout)
        except TimeoutError:
            response = None

        if response == ACK:
            return
        if response == CAN:
            raise RuntimeError("target cancelled XMODEM transfer")
        if response not in (NAK, None):
            raise RuntimeError(f"unexpected XMODEM response 0x{response:02x}")

        if not sys.stderr.isatty():
            continue
        print(f"\nretry block {block_no} ({attempt}/{retries})", file=sys.stderr)

    raise RuntimeError(f"block {block_no} failed after {retries} attempts")


def send_image(port: serial.Serial, image: bytes, timeout: float,
               retries: int, quiet: bool) -> None:
    block_count = (len(image) + BLOCK_SIZE - 1) // BLOCK_SIZE
    if block_count == 0:
        raise ValueError("image is empty")
    if block_count > 255:
        raise ValueError("classic XMODEM supports at most 255 blocks")

    for index in range(block_count):
        start = index * BLOCK_SIZE
        block = image[start:start + BLOCK_SIZE].ljust(BLOCK_SIZE, b"\x1a")
        send_block(port, index + 1, block, timeout, retries)
        if not quiet:
            print(f"\rSent block {index + 1}/{block_count}", end="", flush=True)

    for attempt in range(1, retries + 1):
        port.write(bytes((EOT,)))
        try:
            response = read_byte(port, time.monotonic() + timeout)
        except TimeoutError:
            response = None
        if response == ACK:
            if not quiet:
                print()
            return
        if response == CAN:
            raise RuntimeError("target cancelled at end of transfer")
        if response not in (NAK, None):
            raise RuntimeError(f"unexpected EOT response 0x{response:02x}")
        if not quiet:
            print(f"\nretry EOT ({attempt}/{retries})", file=sys.stderr)

    raise RuntimeError("EOT was not acknowledged")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="BOOT.BIN to send")
    parser.add_argument("--port", required=True, help="serial port, e.g. /dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--command", default="uartload",
                        help="shell command to start UART boot (default: uartload)")
    parser.add_argument("--no-command", action="store_true",
                        help="do not send a shell command; target is already in uartload")
    parser.add_argument("--command-delay", type=float, default=0.03,
                        help="delay between command characters in seconds")
    parser.add_argument("--timeout", type=float, default=3.0,
                        help="per-byte/per-response timeout in seconds")
    parser.add_argument("--retries", type=int, default=16)
    parser.add_argument("--startup-delay", type=float, default=0.2,
                        help="wait after opening the port before sending the command")
    parser.add_argument("--quiet", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    image = args.image.read_bytes()

    if (args.retries < 1 or args.timeout <= 0 or args.startup_delay < 0 or
            args.command_delay < 0):
        raise ValueError("timeout and retries must be positive; delays cannot be negative")

    with serial.Serial(args.port, args.baud, timeout=0.1,
                       write_timeout=args.timeout) as port:
        port.reset_input_buffer()
        time.sleep(args.startup_delay)
        if not args.no_command:
            for byte in (args.command + "\n").encode("ascii"):
                port.write(bytes((byte,)))
                time.sleep(args.command_delay)
        wait_for_crc_request(port, args.timeout * args.retries)
        send_image(port, image, args.timeout, args.retries, args.quiet)

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, TimeoutError, RuntimeError, ValueError) as exc:
        print(f"xmodem_send: {exc}", file=sys.stderr)
        raise SystemExit(1)
