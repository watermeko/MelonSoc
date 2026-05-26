#include "i2c.h"

void i2c_init(uint32_t sys_clk_hz, uint32_t i2c_hz) {
    if (i2c_hz == 0)
        i2c_hz = 100000u;

    uint32_t div = sys_clk_hz / (2u * i2c_hz);
    if (div == 0)
        div = 1;

    *i2c_div_reg() = div & 0xFFFFu;
}

uint32_t i2c_get_status(void) {
    return *i2c_status_reg();
}

void i2c_wait_done(void) {
    while ((i2c_get_status() & I2C_STATUS_DONE) == 0u)
        ;
}

int i2c_write_byte(uint8_t byte, int start, int stop) {
    *i2c_txrx_reg() = (uint32_t)byte;

    uint32_t cmd = I2C_CMD_WRITE;
    if (start)
        cmd |= I2C_CMD_START;
    if (stop)
        cmd |= I2C_CMD_STOP;

    *i2c_cmd_reg() = cmd;
    i2c_wait_done();

    return (i2c_get_status() & I2C_STATUS_NACK) ? 1 : 0;
}

int i2c_probe_7bit(uint8_t addr7) {
    if (addr7 < 0x03 || addr7 > 0x77)
        return 0;

    uint8_t addr_byte = (uint8_t)((addr7 << 1) | 0u);
    return i2c_write_byte(addr_byte, 1, 1) == 0;
}

