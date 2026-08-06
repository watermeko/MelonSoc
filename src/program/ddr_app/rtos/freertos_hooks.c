#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"

static inline uint32_t csr_read(uint32_t csr_addr)
{
    uint32_t val;

    switch (csr_addr) {
        case 0x342:
            asm volatile("csrr %0, mcause" : "=r"(val));
            break;
        case 0x341:
            asm volatile("csrr %0, mepc" : "=r"(val));
            break;
        case 0x300:
            asm volatile("csrr %0, mstatus" : "=r"(val));
            break;
        case 0x343:
            asm volatile("csrr %0, mtval" : "=r"(val));
            break;
        default:
            val = 0;
            break;
    }

    return val;
}

#define UART_DAT_ADDR  0x400008u
#define UART_CTRL_ADDR 0x400010u
#define UART_TX_READY_BIT 8

static void uart_putc(char c)
{
    volatile uint32_t *ctrl = (volatile uint32_t *)UART_CTRL_ADDR;
    volatile uint32_t *dat = (volatile uint32_t *)UART_DAT_ADDR;

    while ((*ctrl & (1u << UART_TX_READY_BIT)) == 0) {
    }

    *dat = (uint32_t)(unsigned char)c;
}

static void uart_puts(const char *s)
{
    while (*s != '\0')
        uart_putc(*s++);
}

static void uart_puthex(uint32_t v)
{
    int i;

    uart_putc('0');
    uart_putc('x');
    for (i = 28; i >= 0; i -= 4) {
        uint32_t nibble = (v >> i) & 0xFu;
        uart_putc((char)(nibble < 10 ? ('0' + nibble) : ('A' + nibble - 10)));
    }
}

void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName)
{
    (void)xTask;

    uart_putc('\n');
    uart_puts("STACK OVERFLOW ");
    if (pcTaskName != NULL)
        uart_puts(pcTaskName);
    uart_putc('\n');

    for (;;) {
    }
}

void vApplicationMallocFailedHook(void)
{
    uart_putc('\n');
    uart_puts("MALLOC FAILED\n");

    for (;;) {
    }
}

void freertos_risc_v_application_exception_handler(void)
{
    uint32_t mcause = csr_read(0x342);
    uint32_t mepc = csr_read(0x341);
    uint32_t mstatus = csr_read(0x300);
    uint32_t mtval = csr_read(0x343);

    uart_putc('\n');
    uart_putc('E');
    uart_putc(' ');
    uart_puthex(mcause);
    uart_putc(' ');
    uart_puthex(mepc);
    uart_putc(' ');
    uart_puthex(mtval);
    uart_putc(' ');
    uart_puthex(mstatus);
    uart_putc('\n');

    for (;;) {
    }
}

void freertos_risc_v_application_interrupt_handler(void)
{
    uint32_t mcause = csr_read(0x342);
    uint32_t mepc = csr_read(0x341);
    uint32_t mstatus = csr_read(0x300);

    uart_putc('\n');
    uart_putc('I');
    uart_putc(' ');
    uart_puthex(mcause);
    uart_putc(' ');
    uart_puthex(mepc);
    uart_putc(' ');
    uart_puthex(mstatus);
    uart_putc('\n');

    for (;;) {
    }
}
