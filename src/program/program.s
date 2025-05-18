.section .text.init 
.global _start      

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
    li sp, RAM_BASE_ADDR
    li gp, IO_BASE_ADDR
    la t0, colormap
    lb a0 , 4(t0)
    call putc_
    ebreak


wait_:
    li t0, 1
    slli t0, t0, wait_bit
wait_L0_:
    addi t0, t0, -1
    bnez t0, wait_L0_
    ret

putc_:
    sw a0, IO_UART_DAT_OFFSET(gp)
    li t0, 1<<9
putc_L0_:
    lw t1, IO_UART_CTRL_OFFSET(gp)
    and t1, t1, t0
    bnez t1, putc_L0_
    ret


.data
.align 2 # Ensure data alignment (optional for .byte, good practice)
colormap:
    .byte ' ', '.', ',', ':'
    .byte ';', 'o', 'x', '%'
    .byte '#', '@', 0, 0   # Null terminators or special values from original