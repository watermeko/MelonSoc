[中文](README_ZH.md)

# Overview

A RISC-V based SoC written in SystemVerilog, running on the Tang Premier 20K. It supports the RV32IMAC instruction set with a five-stage pipeline. Interrupts are supported.

Peripherals include I2C, GPIO, UART, TIMER, and SPI. It uses DDR memory. FreeRTOS and Linux have been ported. Linux is built with Buildroot, based on OpenSBI + BusyBox + Linux Kernel 6.6. A Bootloader is implemented over UART.

# Running

Required software: Git, Verilator, picocom, pyserial, and Gowin EDA/Programmer.
The RV32 toolchain for Linux, musl, BusyBox, Linux, DTB, and OpenSBI are all
provided by Buildroot.

```bash
git submodule update --init --recursive
make build         # Build software
make build_fpga    # Build FPGA firmware
make simulate      # Run simulation
make load          # Download program to SRAM
make load_flash    # Download program to FLASH
make terminal      # Serial terminal
```

# Demo

## Running Linux
![Screenshot](https://github.com/watermeko/picx-images-hosting/raw/master/all/blog/图片.6wrg2ysdyp.webp)

## Running FreeRTOS
![Screenshot](https://github.com/watermeko/picx-images-hosting/raw/master/all/blog/图片.b9jkxakdj.webp)
