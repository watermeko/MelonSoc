# 简介
一个基于risc-v的soc，使用verilog编写，运行在Gowin GW2A上。目前支持RV32IM指令集。
外设现在只有串口。

# 运行
使用的软件：riscv64-unknown-elf-gcc, icarus verilog/verilator, openFPGALoader, picocom
```bash
cd src
make build # 编译程序(src/program/program.s)
make simulate # 使用iverilog仿真器 
make load # 下载程序到SRAM
make load_flash # 下载程序到FLASH

./terminal.sh # 串口

make simulate_verilator # 暂不可用，verilator不支持高云的原语
```
使用串口通信在终端上显示的ANSI图像：
![图片](https://cdn.jsdelivr.net/gh/watermeko/picx-images-hosting@master/all/blog/图片.5fktdo511y.webp)

# TODO
+ 添加更多外设
+ 把DDR作为内存
