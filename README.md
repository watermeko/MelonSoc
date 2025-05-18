# 简介
一个基于risc-v的soc，使用verilog编写，运行在Gowin GW2A上。目前支持RV32I指令集。

# 运行
```bash
cd src
make build # 编译程序(src/program/program.s)
make simulate # 运行仿真(仿真器使用iverilog) 
```

# TODO
+ 添加外设
    + 串口
+ 使用C语言程序
+ 支持RV32IM
