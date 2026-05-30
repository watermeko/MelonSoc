#include "uart.h"

static inline uint32_t uart_read_reg(volatile uint32_t *reg) {
    /*
     * MMIO reads come back through a registered SoC read-data path.
     * When switching addresses, the first read can observe the previous
     * register value, so read twice and use the second sample.
     */
    (void)*reg;
    return *reg;
}

static inline void uart_write_data(uint32_t value) {
    *uart_data_reg() = value;
}

static inline uint32_t uart_read_data(void) {
    return *uart_data_reg();
}

static inline void uart_write_ctrl(uint32_t value) {
    *uart_ctrl_reg() = value;
}

void uart_init(void) {
    uart_clear_status(UART_STATUS_RX_OVERRUN | UART_STATUS_RX_FRAMEERR);
}

void uart_clear_status(uint32_t mask) {
    uint32_t value = 0;

    if (mask & UART_STATUS_RX_OVERRUN)
        value |= UART_STATUS_RX_OVERRUN;

    if (mask & UART_STATUS_RX_FRAMEERR)
        value |= UART_STATUS_RX_FRAMEERR;

    if (value)
        uart_write_ctrl(value);
}

uint32_t uart_get_status(void) {
    return uart_read_reg(uart_ctrl_reg());
}

int uart_tx_ready(void) {
    return (uart_get_status() & UART_STATUS_TX_BUSY) == 0;
}

void uart_putc_blocking(uint8_t byte) {
    while (!uart_tx_ready())
        ;

    uart_write_data(byte);
}

int uart_getc_nonblocking(void) {
    if ((uart_get_status() & UART_STATUS_RX_VALID) == 0)
        return -1;

    return (int)(uart_read_data() & 0xFFu);
}

int uart_getc_blocking(void) {
    int ch;

    do {
        ch = uart_getc_nonblocking();
    } while (ch < 0);

    return ch;
}

int putchar(int c) {
    uart_putc_blocking((uint8_t)c);
    return c & 0xFF;
}

int getchar(void) {
    return uart_getc_blocking();
}
