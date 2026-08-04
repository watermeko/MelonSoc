#include "test_a.h"
#include <stdint.h>
#include "print.h"

static volatile uint32_t a_words[4] __attribute__((aligned(4)));

static uint32_t lr_word(volatile uint32_t *addr) {
    uint32_t value;
    __asm__ volatile("lr.w %0, (%1)" : "=r"(value) : "r"(addr) : "memory");
    return value;
}

static uint32_t sc_word(volatile uint32_t *addr, uint32_t value) {
    uint32_t status;
    __asm__ volatile("sc.w %0, %2, (%1)" : "=r"(status) : "r"(addr), "r"(value) : "memory");
    // (%1)的()表示解引用地址，%1表示addr寄存器的值，%2表示value寄存器的值，%0表示status寄存器的值
    return status;
}

static uint32_t amo_word(unsigned op, volatile uint32_t *addr, uint32_t value) {
    uint32_t old;
    switch (op) {
    case 0: __asm__ volatile("amoadd.w %0, %2, (%1)" : "=r"(old) : "r"(addr), "r"(value) : "memory"); break;
    case 1: __asm__ volatile("amoswap.w %0, %2, (%1)" : "=r"(old) : "r"(addr), "r"(value) : "memory"); break;
    case 2: __asm__ volatile("amoxor.w %0, %2, (%1)" : "=r"(old) : "r"(addr), "r"(value) : "memory"); break;
    case 3: __asm__ volatile("amoand.w %0, %2, (%1)" : "=r"(old) : "r"(addr), "r"(value) : "memory"); break;
    case 4: __asm__ volatile("amoor.w %0, %2, (%1)" : "=r"(old) : "r"(addr), "r"(value) : "memory"); break;
    case 5: __asm__ volatile("amomin.w %0, %2, (%1)" : "=r"(old) : "r"(addr), "r"(value) : "memory"); break;
    case 6: __asm__ volatile("amomax.w %0, %2, (%1)" : "=r"(old) : "r"(addr), "r"(value) : "memory"); break;
    case 7: __asm__ volatile("amominu.w %0, %2, (%1)" : "=r"(old) : "r"(addr), "r"(value) : "memory"); break;
    default: __asm__ volatile("amomaxu.w %0, %2, (%1)" : "=r"(old) : "r"(addr), "r"(value) : "memory"); break;
    }
    return old;
}

void shell_test_a(const char *arg) {
    int pass = 1;
    if (arg && *arg) {
        puts("Usage: test-a");
        return;
    }

    a_words[0] = 10;
    puts("A: LR/SC");
    uint32_t old = lr_word(&a_words[0]);
    uint32_t status = sc_word(&a_words[0], 20);
    if (old != 10 || status != 0 || a_words[0] != 20) { printf("FAIL LR/SC old=%x sc=%x mem=%x\n", old, status, a_words[0]); pass = 0; }

    status = sc_word(&a_words[0], 30);
    if (status != 1 || a_words[0] != 20) { puts("FAIL SC failure"); pass = 0; }

    a_words[0] = 0x100;
    puts("A: AMOADD");
    old = amo_word(0, &a_words[0], 7);
    if (old != 0x100 || a_words[0] != 0x107) { printf("FAIL AMOADD old=%x mem=%x\n", old, a_words[0]); pass = 0; }

    a_words[1] = 0x55aa55aa;
    puts("A: AMOSWAP");
    old = amo_word(1, &a_words[1], 0x12345678);
    if (old != 0x55aa55aa || a_words[1] != 0x12345678) { printf("FAIL AMOSWAP old=%x mem=%x\n", old, a_words[1]); pass = 0; }

    a_words[2] = 0x0f0f0f0f;
    puts("A: AMOXOR");
    old = amo_word(2, &a_words[2], 0xffffffffu);
    if (old != 0x0f0f0f0f || a_words[2] != 0xf0f0f0f0) { printf("FAIL AMOXOR old=%x mem=%x\n", old, a_words[2]); pass = 0; }

    a_words[3] = 0x80000000u;
    puts("A: AMOMINU");
    old = amo_word(7, &a_words[3], 1);
    if (old != 0x80000000u || a_words[3] != 1) { printf("FAIL AMOMINU old=%x mem=%x\n", old, a_words[3]); pass = 0; }

    a_words[0] = 0x0f0f0f0f;
    old = amo_word(3, &a_words[0], 0xff00ff00u);
    if (old != 0x0f0f0f0f || a_words[0] != 0x0f000f00u) { puts("FAIL AMOAND"); pass = 0; }

    a_words[1] = 0x0f0f0f0f;
    old = amo_word(4, &a_words[1], 0xf00000f0u);
    if (old != 0x0f0f0f0f || a_words[1] != 0xff0f0fffU) { puts("FAIL AMOOR"); pass = 0; }

    a_words[2] = 0xfffffff0u;
    old = amo_word(5, &a_words[2], 0x10u);
    if (old != 0xfffffff0u || a_words[2] != 0xfffffff0u) { puts("FAIL AMOMIN"); pass = 0; }

    a_words[3] = 0xfffffff0u;
    old = amo_word(6, &a_words[3], 0x10u);
    if (old != 0xfffffff0u || a_words[3] != 0x10u) { puts("FAIL AMOMAX"); pass = 0; }

    a_words[0] = 0x80000000u;
    old = amo_word(7, &a_words[0], 1u);
    if (old != 0x80000000u || a_words[0] != 1u) { puts("FAIL AMOMINU second"); pass = 0; }

    a_words[1] = 1u;
    old = amo_word(8, &a_words[1], 0x80000000u);
    if (old != 1u || a_words[1] != 0x80000000u) { puts("FAIL AMOMAXU"); pass = 0; }

    if (pass) puts("--- RV32A TEST PASSED ---");
    else puts("--- RV32A TEST FAILED ---");
}
