.section .text.init 
.global _start      

.equ wait_bit, 10

_start:
    li a0, 0
    li s0, 0
    li s1, 16
L0_:
    lb a1, 400(s0) 
    sb a1, 800(s0)
    call wait_
    addi s0, s0, 1
    bne s0, s1, L0_

    li s0, 0
L1_:
    lb a0, 800(s0)
    call wait_
    addi s0, s0, 1
    bne s0, s1, L1_
    ebreak
wait_:
    li t0, 1
    slli t0, t0, wait_bit
L2_:
    addi t0, t0, -1
    bnez t0, L2_
    ret 
