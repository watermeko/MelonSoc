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
    li sp, RAM_BASE_ADDR        
    la gp, IO_BASE_ADDR    
    call main                   

_halt:
    ebreak                      
    j _halt                     


wait_:
    li t0, 1
    slli t0, t0, wait_bit

    addi t0, t0, -1
    bnez t0, wait_L0_
    ret

