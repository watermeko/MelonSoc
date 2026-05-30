#include "ddr.h"

uint32_t ddr_get_status(void) {
    return *ddr_status_reg();
}

int ddr_present(void) {
    return (ddr_get_status() & (1u << DDR_STATUS_PRESENT_BIT)) != 0u;
}

int ddr_init_done(void) {
    return (ddr_get_status() & (1u << DDR_STATUS_INIT_DONE_BIT)) != 0u;
}

static int ddr_wait_not_busy(uint32_t limit) {
    for (uint32_t i = 0; i < limit; ++i) {
        if ((ddr_get_status() & (1u << DDR_STATUS_BUSY_BIT)) == 0u)
            return 0;
    }
    return -1;
}

static int ddr_wait_done(uint32_t limit) {
    for (uint32_t i = 0; i < limit; ++i) {
        if ((ddr_get_status() & (1u << DDR_STATUS_DONE_BIT)) != 0u)
            return 0;
    }
    return -1;
}

static int ddr_start_op(int is_write) {
    uint32_t ctrl = (1u << DDR_CTRL_START_BIT) |
                    (1u << DDR_CTRL_CLR_DONE_BIT) |
                    (1u << DDR_CTRL_CLR_ERR_BIT);
    if (is_write)
        ctrl |= (1u << DDR_CTRL_WRITE_BIT);
    *ddr_ctrl_reg() = ctrl;
    return 0;
}

int ddr_read128(uint32_t app_addr, uint32_t out_words[4]) {
    if (!out_words)
        return -1;
    if (!ddr_present())
        return -2;
    if (!ddr_init_done())
        return -3;
    if (ddr_wait_not_busy(5000000u) != 0)
        return -4;

    *ddr_burst_reg() = 0u;
    *ddr_addr_reg() = app_addr;
    ddr_start_op(0);

    if (ddr_wait_done(20000000u) != 0)
        return -5;

    uint32_t status = ddr_get_status();
    if ((status & (1u << DDR_STATUS_ERR_BIT)) != 0u)
        return -6;

    out_words[0] = *ddr_rdata0_reg();
    out_words[1] = *ddr_rdata1_reg();
    out_words[2] = *ddr_rdata2_reg();
    out_words[3] = *ddr_rdata3_reg();
    return 0;
}

int ddr_write128(uint32_t app_addr, const uint32_t words[4]) {
    if (!words)
        return -1;
    if (!ddr_present())
        return -2;
    if (!ddr_init_done())
        return -3;
    if (ddr_wait_not_busy(5000000u) != 0)
        return -4;

    *ddr_burst_reg() = 0u;
    *ddr_addr_reg() = app_addr;
    *ddr_wdata0_reg() = words[0];
    *ddr_wdata1_reg() = words[1];
    *ddr_wdata2_reg() = words[2];
    *ddr_wdata3_reg() = words[3];

    ddr_start_op(1);

    if (ddr_wait_done(20000000u) != 0)
        return -5;

    uint32_t status = ddr_get_status();
    if ((status & (1u << DDR_STATUS_ERR_BIT)) != 0u)
        return -6;
    return 0;
}
