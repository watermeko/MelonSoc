#ifndef DDR_H
#define DDR_H

#include <stdint.h>

#define IO_BASE_ADDR 0x400000u

#define IO_DDR_CTRL_OFFSET    0x0100u
#define IO_DDR_STATUS_OFFSET  0x0104u
#define IO_DDR_ADDR_OFFSET    0x0108u
#define IO_DDR_BURST_OFFSET   0x010Cu
#define IO_DDR_WDATA0_OFFSET  0x0110u
#define IO_DDR_WDATA1_OFFSET  0x0114u
#define IO_DDR_WDATA2_OFFSET  0x0118u
#define IO_DDR_WDATA3_OFFSET  0x011Cu
#define IO_DDR_RDATA0_OFFSET  0x0120u
#define IO_DDR_RDATA1_OFFSET  0x0124u
#define IO_DDR_RDATA2_OFFSET  0x0128u
#define IO_DDR_RDATA3_OFFSET  0x012Cu

#define DDR_CTRL_START_BIT    0u
#define DDR_CTRL_WRITE_BIT    1u
#define DDR_CTRL_CLR_DONE_BIT 2u
#define DDR_CTRL_CLR_ERR_BIT  3u

#define DDR_STATUS_PRESENT_BIT      0u
#define DDR_STATUS_INIT_DONE_BIT    1u
#define DDR_STATUS_BUSY_BIT         2u
#define DDR_STATUS_DONE_BIT         3u
#define DDR_STATUS_ERR_BIT          4u
#define DDR_STATUS_CMD_RDY_BIT      5u
#define DDR_STATUS_WR_DATA_RDY_BIT  6u
#define DDR_STATUS_RD_VALID_BIT     7u

static inline volatile uint32_t* ddr_ctrl_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_DDR_CTRL_OFFSET);
}

static inline volatile uint32_t* ddr_status_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_DDR_STATUS_OFFSET);
}

static inline volatile uint32_t* ddr_addr_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_DDR_ADDR_OFFSET);
}

static inline volatile uint32_t* ddr_burst_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_DDR_BURST_OFFSET);
}

static inline volatile uint32_t* ddr_wdata0_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_DDR_WDATA0_OFFSET);
}

static inline volatile uint32_t* ddr_wdata1_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_DDR_WDATA1_OFFSET);
}

static inline volatile uint32_t* ddr_wdata2_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_DDR_WDATA2_OFFSET);
}

static inline volatile uint32_t* ddr_wdata3_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_DDR_WDATA3_OFFSET);
}

static inline volatile uint32_t* ddr_rdata0_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_DDR_RDATA0_OFFSET);
}

static inline volatile uint32_t* ddr_rdata1_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_DDR_RDATA1_OFFSET);
}

static inline volatile uint32_t* ddr_rdata2_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_DDR_RDATA2_OFFSET);
}

static inline volatile uint32_t* ddr_rdata3_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_DDR_RDATA3_OFFSET);
}

uint32_t ddr_get_status(void);
int ddr_present(void);
int ddr_init_done(void);
int ddr_read128(uint32_t app_addr, uint32_t out_words[4]);
int ddr_write128(uint32_t app_addr, const uint32_t words[4]);

#endif
