[中文](README_ZH.md)

# Overview

A RISC-V based SoC written in SystemVerilog, running on the Tang Premier 20K. Supports the RV32IMC instruction set with a five-stage pipeline. Interrupts are supported.

Peripherals include I2C, GPIO, UART, TIMER, and SPI. Uses DDR memory. FreeRTOS has been ported.


# Running

Required software: RISC-V cross-compilation toolchain, Verilator, picocom, Gowin EDA/Programmer

```bash
cd src
make build         # Build software
make build_fpga    # Build FPGA firmware
make simulate      # Run simulation
make load          # Download program to SRAM
make load_flash    # Download program to FLASH
make terminal      # Serial terminal
```

# Demo

![Screenshot](https://github.com/watermeko/picx-images-hosting/raw/master/all/blog/%E5%9B%BE%E7%89%87.b9jkxakdj.webp)
