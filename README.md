# 简介
一个基于risc-v的soc，使用verilog编写，运行在Gowin GW2A上。支持RV32IMC指令集，五级流水线，静态调度。
外设有I2C、GPIO、UART、TIMER。

# 运行
使用的软件：riscv64-unknown-elf-gcc, verilator, openFPGALoader, picocom
```bash
cd src
make build # 编译软件
make simulate # 仿真
make load # 下载程序到SRAM
make load_flash # 下载程序到FLASH

./terminal.sh # 串口
```

# TODO
+ 添加更多外设
+ 把DDR作为内存
+ 使用gowin cli
