#include "spi.h"

static uint32_t g_spi_ctrl = SPI_CTRL_CS_N;

void spi_init(uint32_t sys_clk_hz, uint32_t spi_hz) {
    if (spi_hz == 0)
        spi_hz = 200000u;

    uint32_t div = sys_clk_hz / (2u * spi_hz);
    if (div == 0)
        div = 1;

    *spi_div_reg() = div & 0xFFFFu;
    spi_set_cs(1);
}

void spi_set_cs(int cs_n) {
    if (cs_n)
        g_spi_ctrl |= SPI_CTRL_CS_N;
    else
        g_spi_ctrl &= ~SPI_CTRL_CS_N;

    *spi_ctrl_reg() = g_spi_ctrl;
}

uint32_t spi_get_status(void) {
    return *spi_status_reg();
}

uint8_t spi_xfer(uint8_t tx) {
    while ((spi_get_status() & SPI_STATUS_BUSY) != 0u)
        ;

    *spi_txrx_reg() = (uint32_t)tx;
    *spi_ctrl_reg() = g_spi_ctrl | SPI_CTRL_START;

    while ((spi_get_status() & SPI_STATUS_DONE) == 0u)
        ;

    return (uint8_t)(*spi_txrx_reg() & 0xFFu);
}

