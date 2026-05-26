#ifndef SPI_H
#define SPI_H

#include <stdint.h>

#define IO_BASE_ADDR            0x400000u

#define IO_SPI_TXRX_OFFSET      0x50u
#define IO_SPI_CTRL_OFFSET      0x54u
#define IO_SPI_STATUS_OFFSET    0x58u
#define IO_SPI_DIV_OFFSET       0x5Cu

#define SPI_CTRL_CS_N           (1u << 0) /* 1=deassert, 0=assert */
#define SPI_CTRL_START          (1u << 1) /* pulse */

#define SPI_STATUS_BUSY         (1u << 0)
#define SPI_STATUS_DONE         (1u << 1)

static inline volatile uint32_t* spi_txrx_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_SPI_TXRX_OFFSET);
}

static inline volatile uint32_t* spi_ctrl_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_SPI_CTRL_OFFSET);
}

static inline volatile uint32_t* spi_status_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_SPI_STATUS_OFFSET);
}

static inline volatile uint32_t* spi_div_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_SPI_DIV_OFFSET);
}

void spi_init(uint32_t sys_clk_hz, uint32_t spi_hz);
void spi_set_cs(int cs_n);
uint32_t spi_get_status(void);
uint8_t spi_xfer(uint8_t tx);

#endif /* SPI_H */

