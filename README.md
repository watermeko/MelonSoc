# 简介
一个基于RISC-V的SoC，使用SystemVerilog编写，运行在Gowin GW2A上。支持RV32IMC指令集，五级流水线，静态调度。
外设有I2C、GPIO、UART、TIMER、SPI。

# 运行
使用的软件：riscv64-unknown-elf-gcc, verilator, openFPGALoader, picocom, gowin eda
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
![PIC](https://github.com/watermeko/picx-images-hosting/raw/master/all/blog/图片.7lkgwh9fgb.webp)
# TODO
+ 添加更多外设
+ 把DDR作为内存
