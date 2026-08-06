    .section .text
    .align 2
    .global test_sv32_data
    .global sv32_fault_test
    .global sv32_instruction_test
    .global sv32_instruction_fault_test

    .equ ROOT_PT, 0x80010000
    .equ LEAF_PT, 0x80011000
    .equ TEST_VA, 0x40000000

test_sv32_data:
    addi sp, sp, -32
    sw ra, 28(sp)
    sw s0, 24(sp)
    sw s1, 20(sp)
    sw s2, 16(sp)
    mv s0, sp
    csrr s1, mstatus
    csrr s2, satp

    li t0, ROOT_PT
    li t1, LEAF_PT
    li t2, 0
    sw t2, 0(t0)
    sw t2, 0(t1)

    # Root entry 256 points at LEAF_PT.
    srli t3, t1, 12
    slli t3, t3, 10
    ori t3, t3, 1
    sw t3, 1024(t0)

    # Map TEST_VA to the physical page containing sv32_test_word.
    la t4, sv32_test_word
    srli t3, t4, 12
    slli t3, t3, 10
    ori t3, t3, 0x007       # V|R|W; hardware must set A/D.
    sw t3, 0(t1)

    li t3, 0x13579bdf
    sw t3, 0(t4)
    slli t5, t4, 20
    srli t5, t5, 20
    li t6, TEST_VA
    add t6, t6, t5

    # Enable Sv32 and make M-mode data accesses use S privilege.
    srli t3, t0, 12
    li t3, 0x80080010       # MODE=Sv32, root PPN=0x80010
    csrw satp, t3
    sfence.vma zero, zero
    mv t3, s1
    li t2, ~((3 << 11) | (1 << 17))
    and t3, t3, t2
    li t2, (1 << 11) | (1 << 17)
    or t3, t3, t2
    csrw mstatus, t3

    lw a1, 0(t6)
    li a2, 0x2468ace0
    sw a2, 0(t6)

    # Restore physical M-mode data accesses before touching the stack.
    csrw mstatus, s1
    csrw satp, s2
    sfence.vma zero, zero

    li t3, 0x13579bdf
    bne a1, t3, sv32_fail_load
    lw t3, 0(t4)
    bne t3, a2, sv32_fail_store
    lw t3, 0(t1)
    andi t3, t3, 0xc0
    li t2, 0xc0
    bne t3, t2, sv32_fail_ad
    li a0, 0
    j sv32_finish

sv32_fail_load:
    li a0, 1
    j sv32_finish

sv32_fail_store:
    li a0, 2
    j sv32_finish

sv32_fail_ad:
    li a0, 3

sv32_finish:
    mv sp, s0
    lw s2, 16(sp)
    lw s1, 20(sp)
    lw s0, 24(sp)
    lw ra, 28(sp)
    addi sp, sp, 32
    ret

sv32_fault_test:
    addi sp, sp, -32
    sw ra, 28(sp)
    sw s0, 24(sp)
    sw s1, 20(sp)
    sw s2, 16(sp)
    mv s0, sp
    csrr s1, mstatus
    csrr s2, mtvec

    li t0, ROOT_PT
    li t1, LEAF_PT
    li t2, 0
    sw t2, 0(t0)
    sw t2, 0(t1)
    srli t3, t1, 12
    slli t3, t3, 10
    ori t3, t3, 1
    sw t3, 1024(t0)

    la t0, sv32_fault_handler
    csrw mtvec, t0
    li t0, 0x80080010
    csrw satp, t0
    sfence.vma zero, zero
    mv t0, s1
    li t1, ~((3 << 11) | (1 << 17))
    and t0, t0, t1
    li t1, (1 << 11) | (1 << 17)
    or t0, t0, t1
    csrw mstatus, t0
    li t0, TEST_VA
    lw zero, 0(t0)

    li a0, 3
    j sv32_fault_finish

sv32_fault_handler:
    # Disable MPRV before any stack access in the M-mode handler.
    csrr t0, mstatus
    li t1, ~(1 << 17)
    and t0, t0, t1
    csrw mstatus, t0
    csrr t0, mcause
    li t1, 13
    bne t0, t1, sv32_fault_bad_cause
    csrr t0, mtval
    li t1, TEST_VA
    bne t0, t1, sv32_fault_bad_tval
    li a0, 0
    j sv32_fault_finish

sv32_fault_bad_cause:
    li a0, 1
    j sv32_fault_finish

sv32_fault_bad_tval:
    li a0, 2

sv32_fault_finish:
    csrw mstatus, s1
    csrw mtvec, s2
    csrw satp, zero
    sfence.vma zero, zero
    mv sp, s0
    lw s2, 16(sp)
    lw s1, 20(sp)
    lw s0, 24(sp)
    lw ra, 28(sp)
    addi sp, sp, 32
    ret

sv32_instruction_test:
    addi sp, sp, -32
    sw ra, 28(sp)
    sw s0, 24(sp)
    sw s1, 20(sp)
    sw s2, 16(sp)
    mv s0, sp
    csrr s1, mstatus
    csrr s2, mtvec

    # A level-1 leaf identity maps VA 0..4MiB as supervisor RX.
    li t0, ROOT_PT
    li t1, 0x4b           # V|R|X|A, PPN=0
    sw t1, 0(t0)
    la t0, sv32_instruction_trap
    csrw mtvec, t0
    la t0, sv32_s_entry
    csrw mepc, t0
    li t0, 0x80080010
    csrw satp, t0
    sfence.vma zero, zero
    mv t0, s1
    li t1, ~(3 << 11)
    and t0, t0, t1
    li t1, (1 << 11)
    or t0, t0, t1
    csrw mstatus, t0
    mret

sv32_s_entry:
    li a0, 0x5a
    ecall

    .align 2
sv32_instruction_trap:
    csrr t0, mcause
    li t1, 9
    bne t0, t1, sv32_instruction_bad
    li t0, 0x5a
    bne a0, t0, sv32_instruction_bad
    li a0, 0
    j sv32_instruction_return

sv32_instruction_bad:
    li a0, 1

sv32_instruction_return:
    csrw satp, zero
    sfence.vma zero, zero
    la t0, sv32_instruction_finish
    csrw mepc, t0
    csrr t0, mstatus
    li t1, ~(3 << 11)
    and t0, t0, t1
    li t1, (3 << 11)
    or t0, t0, t1
    csrw mstatus, t0
    mret

sv32_instruction_finish:
    csrw mstatus, s1
    csrw mtvec, s2
    mv sp, s0
    lw s2, 16(sp)
    lw s1, 20(sp)
    lw s0, 24(sp)
    lw ra, 28(sp)
    addi sp, sp, 32
    ret

sv32_instruction_fault_test:
    addi sp, sp, -32
    sw ra, 28(sp)
    sw s0, 24(sp)
    sw s1, 20(sp)
    sw s2, 16(sp)
    mv s0, sp
    csrr s1, mstatus
    csrr s2, mtvec

    # Valid supervisor page with A set, but no execute permission.
    li t0, ROOT_PT
    li t1, 0x43           # V|R|A, PPN=0
    sw t1, 0(t0)
    la t0, sv32_instruction_fault_handler
    csrw mtvec, t0
    la t0, sv32_instruction_fault_target
    csrw mepc, t0
    li t0, 0x80080010
    csrw satp, t0
    sfence.vma zero, zero
    mv t0, s1
    li t1, ~(3 << 11)
    and t0, t0, t1
    li t1, (1 << 11)
    or t0, t0, t1
    csrw mstatus, t0
    mret

sv32_instruction_fault_target:
    li a0, 3
    ecall

    .align 2
sv32_instruction_fault_handler:
    csrr t0, mcause
    li t1, 12
    bne t0, t1, sv32_instruction_fault_bad_cause
    csrr t0, mtval
    la t1, sv32_instruction_fault_target
    bne t0, t1, sv32_instruction_fault_bad_tval
    li a0, 0
    j sv32_instruction_fault_return

sv32_instruction_fault_bad_cause:
    li a0, 1
    j sv32_instruction_fault_return

sv32_instruction_fault_bad_tval:
    li a0, 2

sv32_instruction_fault_return:
    csrw satp, zero
    sfence.vma zero, zero
    la t0, sv32_instruction_fault_finish
    csrw mepc, t0
    csrr t0, mstatus
    li t1, ~(3 << 11)
    and t0, t0, t1
    li t1, (3 << 11)
    or t0, t0, t1
    csrw mstatus, t0
    mret

sv32_instruction_fault_finish:
    csrw mstatus, s1
    csrw mtvec, s2
    mv sp, s0
    lw s2, 16(sp)
    lw s1, 20(sp)
    lw s0, 24(sp)
    lw ra, 28(sp)
    addi sp, sp, 32
    ret

    .section .bss
    .align 2
sv32_test_word:
    .word 0
