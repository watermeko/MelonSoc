.section .text.init 
.global _start      
.global putchar     # 使 putchar 对 C 可见

.equ wait_bit, 1

.equ RAM_BASE_ADDR, 0x1800
.equ IO_BASE_ADDR, 0x400000

.equ IO_LEDS_BIT, 0
.equ IO_UART_DAT_BIT, 1
.equ IO_UART_CTRL_BIT, 2

.equ IO_LEDS_OFFSET, (1 << IO_LEDS_BIT) * 4
.equ IO_UART_DAT_OFFSET, (1 << IO_UART_DAT_BIT) * 4
.equ IO_UART_CTRL_OFFSET, (1 << IO_UART_CTRL_BIT) * 4


_start:
    li sp, RAM_BASE_ADDR        # 初始化堆栈指针
    li gp, IO_BASE_ADDR         # 初始化全局指针 (putchar 会使用它)
    call main                   # 调用 C main 函数

_halt:
    ebreak                      # main 函数返回后停止处理器
    j _halt                     # 无限循环


wait_:
    li t0, 1
    slli t0, t0, wait_bit
wait_L0_:
    addi t0, t0, -1
    bnez t0, wait_L0_
    ret

putchar:                        # 通过 UART 输出字符的函数
    # a0 包含要打印的字符
    sw a0, IO_UART_DAT_OFFSET(gp) # 将字符写入 UART 数据寄存器
    li t0, 1<<9                   # UART TX 繁忙位掩码 (假设 CTRL 寄存器的第 9 位是 TX 繁忙)
putchar_busy_wait_L0_:
    lw t1, IO_UART_CTRL_OFFSET(gp) # 读取 UART 控制/状态寄存器
    and t1, t1, t0                # 检查繁忙位是否设置
    bnez t1, putchar_busy_wait_L0_ # 如果繁忙则循环
    ret                           # 从 putchar 返回