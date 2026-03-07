#include "test_msip.h"
#include "msip.h"
#include "test_csr.h"

int printf(const char *fmt, ...);
int puts(const char *s);

void shell_test_msip(const char *arg) {
    if (arg && *arg) {
        puts("Usage: test-msip");
        return;
    }

    printf("--- Machine Software Interrupt (MSIP) Test Start ---\n");

    uint32_t trap_addr = (uint32_t)&trap_handler;
    asm volatile("csrw mtvec, %0" :: "r"(trap_addr));

    trap_hit_flag  = 0;
    trap_cause_val = 0;

    msip_clear();

    asm volatile("csrs mie, %0" :: "r"(1 << 3));
    asm volatile("csrs mstatus, %0" :: "r"(1 << 3));

    printf("Triggering software interrupt via MSIP MMIO...\n");
    msip_trigger();

    int timeout = 0;
    while (!trap_hit_flag) {
        timeout++;
        if (timeout > 1000000) {
            printf("[FAIL] Timeout waiting for software interrupt.\n");
            break;
        }
    }

    asm volatile("csrc mstatus, %0" :: "r"(1 << 3));
    asm volatile("csrc mie, %0" :: "r"(1 << 3));

    if (trap_hit_flag) {
        if (trap_cause_val == 0x80000003) {
            printf("[OK] Software interrupt triggered and handled (cause=0x%x).\n",
                   trap_cause_val);
            printf("--- MSIP TEST PASSED! ---\n");
        } else {
            printf("[FAIL] Wrong cause: 0x%x (expected 0x80000003)\n", trap_cause_val);
        }
    }
}
