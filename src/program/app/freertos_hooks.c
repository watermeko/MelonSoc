/*
 * FreeRTOS application hooks for MelonSoC.
 *
 * The default handlers in portASM.S are weak-symbol infinite loops.
 * These strong-symbol C replacements capture machine state, print
 * diagnostics, and halt cleanly instead of silently spinning.
 */

#include <stdint.h>

/* ---- helpers ------------------------------------------------------------- */

static inline uint32_t csr_read(uint32_t csr_addr) {
    uint32_t val;
    switch (csr_addr) {
        case 0x342: asm volatile("csrr %0, mcause"   : "=r"(val)); break;
        case 0x341: asm volatile("csrr %0, mepc"      : "=r"(val)); break;
        case 0x300: asm volatile("csrr %0, mstatus"   : "=r"(val)); break;
        case 0x343: asm volatile("csrr %0, mtval"     : "=r"(val)); break;
        default:    val = 0; break;
    }
    return val;
}

/* ---- UART output (minimal, no driver dependency) ------------------------ */
#define UART_DAT_ADDR  0x400008u
#define UART_CTRL_ADDR 0x400010u
#define UART_TX_READY_BIT 8

static void uart_putc(char c) {
    volatile uint32_t *ctrl = (volatile uint32_t *)UART_CTRL_ADDR;
    volatile uint32_t *dat  = (volatile uint32_t *)UART_DAT_ADDR;
    while (!(*ctrl & (1u << UART_TX_READY_BIT))) {}
    *dat = (uint32_t)(unsigned char)c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static void uart_puthex(uint32_t v) {
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xFu]);
}

/* ---- exception / interrupt handlers (override portASM.S weak stubs) ----- */

void freertos_risc_v_application_exception_handler(void) {
    uint32_t mcause  = csr_read(0x342);
    uint32_t mepc    = csr_read(0x341);
    uint32_t mstatus = csr_read(0x300);
    uint32_t mtval   = csr_read(0x343);

    uart_puts("\n[EXCEPTION] mcause=");
    uart_puthex(mcause);
    uart_puts(" mepc=");
    uart_puthex(mepc);
    uart_puts(" mtval=");
    uart_puthex(mtval);
    uart_puts(" mstatus=");
    uart_puthex(mstatus);
    uart_puts("\nHalted.\n");

    for (;;) {}
}

void freertos_risc_v_application_interrupt_handler(void) {
    uint32_t mcause  = csr_read(0x342);
    uint32_t mepc    = csr_read(0x341);
    uint32_t mstatus = csr_read(0x300);

    uart_puts("\n[UNHANDLED INTERRUPT] mcause=");
    uart_puthex(mcause);
    uart_puts(" mepc=");
    uart_puthex(mepc);
    uart_puts(" mstatus=");
    uart_puthex(mstatus);
    uart_puts("\nSpinning.\n");

    for (;;) {}
}
