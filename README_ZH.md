[English](README.md)

# 简介
一个基于RISC-V的SoC，使用SystemVerilog编写，运行在 Tang Premier 20K 上。支持RV32IMC指令集，五级流水线。支持中断。
外设有I2C、GPIO、UART、TIMER、SPI。使用DDR内存。
移植了FreeRTOS。

# 运行
使用的软件：riscv交叉编译工具, verilator, picocom, gowin eda/programmer
```bash
cd src
make build # 编译软件
make build_fpga # 编译固件
make simulate # 仿真
make load # 下载程序到SRAM
make load_flash # 下载程序到FLASH
make terminal # 串口终端
```

# 运行效果
![图片](https://github.com/watermeko/picx-images-hosting/raw/master/all/blog/图片.b9jkxakdj.webp)

