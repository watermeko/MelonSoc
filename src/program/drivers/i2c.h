#ifndef I2C_H
#define I2C_H

#include <stdint.h>

#define IO_BASE_ADDR           0x400000u
#define IO_I2C_TXRX_OFFSET     0x20u
#define IO_I2C_CMD_OFFSET      0x24u
#define IO_I2C_STATUS_OFFSET   0x28u
#define IO_I2C_DIV_OFFSET      0x2Cu

#define I2C_CMD_START (1u << 0)
#define I2C_CMD_STOP  (1u << 1)
#define I2C_CMD_WRITE (1u << 2)
#define I2C_CMD_READ  (1u << 3)
#define I2C_CMD_ACK   (1u << 4) /* for READ: 1=ACK, 0=NACK */

#define I2C_STATUS_BUSY (1u << 0)
#define I2C_STATUS_DONE (1u << 1)
#define I2C_STATUS_NACK (1u << 2)

static inline volatile uint32_t* i2c_txrx_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_I2C_TXRX_OFFSET);
}

static inline volatile uint32_t* i2c_cmd_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_I2C_CMD_OFFSET);
}

static inline volatile uint32_t* i2c_status_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_I2C_STATUS_OFFSET);
}

static inline volatile uint32_t* i2c_div_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_I2C_DIV_OFFSET);
}

void i2c_init(uint32_t sys_clk_hz, uint32_t i2c_hz);
uint32_t i2c_get_status(void);
void i2c_wait_done(void);
int i2c_write_byte(uint8_t byte, int start, int stop);
int i2c_probe_7bit(uint8_t addr7);

#endif /* I2C_H */

