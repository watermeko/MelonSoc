#include "test_csr.h"

volatile uint32_t trap_cause_val = 0;
volatile int trap_hit_flag = 0;

INTERRUPT_ATTR void trap_handler(void) {
    uint32_t cause;
    asm volatile("csrr %0, mcause" : "=r"(cause));

    trap_cause_val = cause;
    trap_hit_flag = 1;

    if ((cause & 0x80000000) == 0) {
        uint32_t epc;
        asm volatile("csrr %0, mepc" : "=r"(epc));
        epc += 4;
        asm volatile("csrw mepc, %0" :: "r"(epc));
    } else {
        if ((cause & 0xFF) == 7) {
            *((volatile uint32_t*)(0x400044u)) = 1; // 写TIMER STATUS寄存器，清除外设中断标志
        }
    }
}
