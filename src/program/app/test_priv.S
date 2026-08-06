    .section .text
    .align 2
    .global test_privilege_modes

test_privilege_modes:
    addi sp, sp, -32
    sw ra, 28(sp)
    sw s0, 24(sp)
    mv s0, sp
    csrr t0, mtvec
    sw t0, 20(sp)
    csrr t0, stvec
    sw t0, 16(sp)
    csrr t0, medeleg
    sw t0, 12(sp)
    csrr t0, mstatus
    sw t0, 8(sp)

    la t0, priv_m_trap
    csrw mtvec, t0
    la t0, priv_s_trap
    csrw stvec, t0
    li t0, (1 << 8)
    csrw medeleg, t0
    la t0, priv_s_entry
    csrw mepc, t0
    csrr t1, mstatus
    li t2, ~(3 << 11)
    and t1, t1, t2
    li t2, (1 << 11)
    or t1, t1, t2
    csrw mstatus, t1
    mret

priv_s_entry:
    csrr t0, sstatus
    la t1, priv_u_entry
    csrw sepc, t1
    li t1, ~(1 << 8)
    and t0, t0, t1
    csrw sstatus, t0
    sret

priv_u_entry:
    ecall
priv_u_after_ecall:
    csrr t0, mscratch
    li a0, 2
    j priv_finish

priv_s_trap:
    csrr t0, scause
    li t1, 8
    bne t0, t1, priv_s_fail
    csrr t0, sepc
    addi t0, t0, 4
    csrw sepc, t0
    sret

priv_s_fail:
    li a0, 3
    j priv_finish

priv_m_trap:
    csrr t0, mcause
    li t1, 2
    bne t0, t1, priv_m_fail
    li a0, 0
    j priv_finish

priv_m_fail:
    li a0, 4

priv_finish:
    lw t0, 20(s0)
    csrw mtvec, t0
    lw t0, 16(s0)
    csrw stvec, t0
    lw t0, 12(s0)
    csrw medeleg, t0
    lw t0, 8(s0)
    csrw mstatus, t0
    mv sp, s0
    lw s0, 24(sp)
    lw ra, 28(sp)
    addi sp, sp, 32
    ret
