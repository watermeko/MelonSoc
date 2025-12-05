.section .text.init 
.global _start      

.equ wait_bit, 1

.equ RAM_BASE_ADDR, 0x20000  # DATARAM顶端地址 (64KB数据内存)，用于栈指针初始化
.equ IO_BASE_ADDR, 0x400000

.equ IO_LEDS_BIT, 0
.equ IO_UART_DAT_BIT, 1
.equ IO_UART_CTRL_BIT, 2

.equ IO_LEDS_OFFSET, (1 << IO_LEDS_BIT) * 4
.equ IO_UART_DAT_OFFSET, (1 << IO_UART_DAT_BIT) * 4
.equ IO_UART_CTRL_OFFSET, (1 << IO_UART_CTRL_BIT) * 4


_start:
    li sp, RAM_BASE_ADDR        # 初始化堆栈指针
    la gp, __global_pointer$    # 初始化全局指针，供编译器访问小数据
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

