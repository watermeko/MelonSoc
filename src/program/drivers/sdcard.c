#include "sdcard.h"

#define IO_BASE_ADDR      0x400000u
#define IO_SD_CMD_ADDR    (IO_BASE_ADDR + 0x60u)
#define IO_SD_ARG_ADDR    (IO_BASE_ADDR + 0x64u)
#define IO_SD_CTRL_ADDR   (IO_BASE_ADDR + 0x68u)
#define IO_SD_RESP0_ADDR  (IO_BASE_ADDR + 0x6Cu)
#define IO_SD_DEBUG_ADDR  (IO_BASE_ADDR + 0x70u)
#define IO_SD_DATA_ADDR   (IO_BASE_ADDR + 0x80u)

#define SD_CTRL_START     0x01u
#define SD_CTRL_CLEAR     0x02u
#define SD_CTRL_READ      0x08u
#define SD_ST_BUSY        0x01u
#define SD_ST_DONE        0x02u
#define SD_ST_ERR         0x04u

static uint8_t g_sd_err;
static uint16_t g_rca;
static uint32_t g_last_status;
static uint32_t g_last_debug;
static uint32_t g_last_resp;

static inline volatile uint32_t *reg32(uint32_t addr) {
    return (volatile uint32_t *)addr;
}

static void sd_delay(void) {
    for (volatile int wait = 0; wait < 10000; ++wait)
        ;
}

uint8_t sdcard_last_error(void) {
    return g_sd_err;
}

uint32_t sdcard_last_status(void) {
    return g_last_status;
}

uint32_t sdcard_last_debug(void) {
    return g_last_debug;
}

static int sd_cmd(uint32_t cmd, uint32_t arg, int read_block) {
    sd_delay();
    *reg32(IO_SD_CTRL_ADDR) = SD_CTRL_CLEAR;
    *reg32(IO_SD_ARG_ADDR) = arg;
    *reg32(IO_SD_CMD_ADDR) = cmd;
    *reg32(IO_SD_CTRL_ADDR) = SD_CTRL_START | (read_block ? SD_CTRL_READ : 0u);

    uint32_t timeout = 2000000u;
    while (timeout--) {
        uint32_t st = *reg32(IO_SD_CTRL_ADDR);
        if (st & SD_ST_DONE) {
            g_last_status = st;
            g_last_debug = *reg32(IO_SD_DEBUG_ADDR);
            g_last_resp = *reg32(IO_SD_RESP0_ADDR);
            return (st & SD_ST_ERR) ? -1 : 0;
        }
    }
    g_last_status = *reg32(IO_SD_CTRL_ADDR);
    g_last_debug = *reg32(IO_SD_DEBUG_ADDR);
    g_last_resp = *reg32(IO_SD_RESP0_ADDR);
    return -1;
}

int sdcard_init(void) {
    g_sd_err = 0;

    (void)sd_cmd(0, 0, 0);
    if (sd_cmd(8, 0x000001AAu, 0) != 0) { g_sd_err = 8; return -1; }

    for (uint32_t i = 0; i < 1000; ++i) {
        if (sd_cmd(55, 0, 0) != 0) { g_sd_err = 55; return -1; }
        if (sd_cmd(41, 0x40300000u, 0) != 0) { g_sd_err = 41; return -1; }
        if (g_last_resp & 0x80000000u)
            break;
    }
    if ((g_last_resp & 0x80000000u) == 0) { g_sd_err = 41; return -1; }

    if (sd_cmd(2, 0, 0) != 0) { g_sd_err = 2; return -1; }
    if (sd_cmd(3, 0, 0) != 0) { g_sd_err = 3; return -1; }
    g_rca = (uint16_t)(g_last_resp >> 16);
    if (g_rca == 0) { g_sd_err = 3; return -1; }
    if (sd_cmd(7, (uint32_t)g_rca << 16, 0) != 0) { g_sd_err = 7; return -1; }
    if (sd_cmd(16, 512, 0) != 0) { g_sd_err = 16; return -1; }

    return 0;
}

int sdcard_read_block(uint32_t lba, uint8_t out512[512]) {
    if (sd_cmd(17, lba, 1) != 0) {
        g_sd_err = 17;
        return -1;
    }
    sd_delay();

    for (uint32_t i = 0; i < 128; ++i) {
        uint32_t w = reg32(IO_SD_DATA_ADDR)[i];
        out512[i * 4u + 0u] = (uint8_t)(w >> 24);
        out512[i * 4u + 1u] = (uint8_t)(w >> 16);
        out512[i * 4u + 2u] = (uint8_t)(w >> 8);
        out512[i * 4u + 3u] = (uint8_t)w;
    }
    g_sd_err = 0;
    return 0;
}
