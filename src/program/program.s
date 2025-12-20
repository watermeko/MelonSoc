.section .text 
.global _start      

.global rdcycle
.global rdinstret

.equ wait_bit, 1

.equ RAM_BASE_ADDR, 0x18000  # DATARAM顶端地址 (32KB数据内存)，用于栈指针初始化
.equ IO_BASE_ADDR, 0x400000

.equ IO_LEDS_BIT, 0
.equ IO_UART_DAT_BIT, 1
.equ IO_UART_CTRL_BIT, 2

.equ IO_LEDS_OFFSET, (1 << IO_LEDS_BIT) * 4
.equ IO_UART_DAT_OFFSET, (1 << IO_UART_DAT_BIT) * 4
.equ IO_UART_CTRL_OFFSET, (1 << IO_UART_CTRL_BIT) * 4


_start:
    li sp, RAM_BASE_ADDR        
    .option push
    .option norelax
    la gp, __global_pointer$    
    .option pop
    la t0, __bss_start
    la t1, __bss_end
    li t2, 0
1:
    beq t0, t1, 2f
    sw t2, 0(t0)
    addi t0, t0, 4
    bltu t0, t1, 1b
2:
    call main                   

_halt:
    ebreak                      
    j _halt                     


wait_:
    li t0, 1
    slli t0, t0, wait_bit
wait_L0_:
    addi t0, t0, -1
    bnez t0, wait_L0_
    ret

rdcycle:
.L0:  
   rdcycleh a1
   rdcycle a0
   rdcycleh t0
   bne a1,t0,.L0
   ret

rdinstret:
.L1:  
   rdinstreth a1
   rdinstret a0
   rdinstreth t0
   bne a1,t0,.L1
   ret
