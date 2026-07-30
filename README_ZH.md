[English](README.md)

# 简介
一个基于RISC-V的SoC，使用SystemVerilog编写，运行在 Tang Premier 20K 上。支持RV32IMC指令集，五级流水线。支持中断。
外设有I2C、GPIO、UART、TIMER、SPI。使用DDR内存。
移植了FreeRTOS。

# 运行
使用的软件：riscv交叉编译工具, verilator, picocom, pyserial, gowin eda/programmer
```bash
make build # 编译软件
make build_fpga # 编译固件
make simulate # 仿真
make load # 下载程序到SRAM
make load_flash # 下载程序到FLASH
make terminal # 串口终端
```

以上命令从仓库根目录执行；`make build_fpga` 和 `make load` 依赖根目录的 FPGA 工程。

UART Bootloader：先执行 `make build` 生成 `src/build/BOOT.BIN`，再退出串口终端，使用：

```bash
python3 src/program/tools/xmodem_send.py \
    --port /dev/ttyUSB1 \
    --baud 115200 \
    src/build/BOOT.BIN
```

工具会以逐字符方式向一级程序发送 `uartload`，然后使用 XMODEM-CRC 分块下载到 DDR，适配当前无 RX FIFO 的 UART。
也可以先在终端手动输入 `uartload`，再使用 `--no-command` 发送镜像。

UART Boot 仿真：

```bash
make simulate SIM_XMODEM_IMAGE="build/BOOT.BIN"
make simulate SIM_XMODEM_IMAGE="build/BOOT.BIN" SIM_XMODEM_CORRUPT_BLOCK=3
```

CPU 算术右移与窄整数 CRC 回归：

```bash
make simulate SIM_CMD="test-shift"
```

# 运行效果
![图片](https://github.com/watermeko/picx-images-hosting/raw/master/all/blog/图片.b9jkxakdj.webp)
