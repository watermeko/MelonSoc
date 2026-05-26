#ifndef UART_H
#define UART_H

#include <stdint.h>

#define IO_BASE_ADDR        0x400000u
#define IO_UART_DAT_OFFSET  0x8u
#define IO_UART_CTRL_OFFSET 0x10u

#define UART_STATUS_RX_VALID    (1u << 0)
#define UART_STATUS_RX_OVERRUN  (1u << 1)
#define UART_STATUS_RX_FRAMEERR (1u << 2)
#define UART_STATUS_TX_READY    (1u << 8)
#define UART_STATUS_TX_BUSY     (1u << 9)

static inline volatile uint32_t* uart_data_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_UART_DAT_OFFSET);
}

static inline volatile uint32_t* uart_ctrl_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_UART_CTRL_OFFSET);
}

void uart_init(void);
void uart_clear_status(uint32_t mask);
uint32_t uart_get_status(void);
int uart_tx_ready(void);
void uart_putc_blocking(uint8_t byte);
int uart_getc_nonblocking(void);
int uart_getc_blocking(void);

int putchar(int c);
int getchar(void);

static inline int uart_rx_available(void) {
    return (uart_get_status() & UART_STATUS_RX_VALID) != 0;
}

#endif /* UART_H */
