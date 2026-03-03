#include "sdcard.h"
#include "spi.h"

enum {
    R1_IDLE = 0x01,
    R1_OK = 0x00,
};

enum {
    CMD0 = 0x40 + 0,
    CMD8 = 0x40 + 8,
    CMD16 = 0x40 + 16,
    CMD17 = 0x40 + 17,
    CMD55 = 0x40 + 55,
    CMD58 = 0x40 + 58,
    ACMD41 = 0x40 + 41,
};

static int g_sd_inited;
static int g_sd_sdhc;
static uint8_t g_sd_err;

enum {
    SD_E_NONE = 0x00,
    SD_E_CMD0 = 0x01,
    SD_E_CMD8 = 0x02,
    SD_E_ACMD41 = 0x03,
    SD_E_CMD58 = 0x04,
    SD_E_CMD16 = 0x05,
    SD_E_CMD17 = 0x06,
    SD_E_TOKEN = 0x07,
};

uint8_t sdcard_last_error(void) {
    return g_sd_err;
}

static void sd_select(void) {
    spi_set_cs(0);
}

static void sd_deselect(void) {
    spi_set_cs(1);
    (void)spi_xfer(0xFF);
}

static uint8_t sd_wait_r1(uint32_t tries) {
    while (tries--) {
        uint8_t r = spi_xfer(0xFF);
        if (r != 0xFF)
            return r;
    }
    return 0xFF;
}

static int sd_send_cmd(uint8_t cmd, uint32_t arg, uint8_t crc, uint8_t *r1_out) {
    (void)spi_xfer(0xFF);

    (void)spi_xfer(cmd);
    (void)spi_xfer((uint8_t)(arg >> 24));
    (void)spi_xfer((uint8_t)(arg >> 16));
    (void)spi_xfer((uint8_t)(arg >> 8));
    (void)spi_xfer((uint8_t)(arg >> 0));
    (void)spi_xfer(crc);

    uint8_t r1 = sd_wait_r1(0xFFFFu);
    if (r1_out)
        *r1_out = r1;
    return (r1 == 0xFF) ? -1 : 0;
}

static int sd_send_acmd41(int hcs, uint8_t *r1_out) {
    uint8_t r1;
    if (sd_send_cmd(CMD55, 0, 0xFF, &r1) != 0)
        return -1;
    if (r1 > 1)
        return -1;
    return sd_send_cmd(ACMD41, hcs ? 0x40000000u : 0u, 0xFF, r1_out);
}

int sdcard_init(void) {
    if (g_sd_inited)
        return 0;

    g_sd_sdhc = 0;
    g_sd_err = SD_E_NONE;

    // Put card into SPI mode: >= 74 clocks with CS high.
    spi_set_cs(1);
    for (int i = 0; i < 10; ++i)
        (void)spi_xfer(0xFF);

    sd_select();

    uint8_t r1;
    if (sd_send_cmd(CMD0, 0, 0x95, &r1) != 0 || r1 != R1_IDLE) {
        g_sd_err = SD_E_CMD0;
        sd_deselect();
        return -1;
    }

    int sd_v2 = 0;
    if (sd_send_cmd(CMD8, 0x000001AAu, 0x87, &r1) == 0 && r1 == R1_IDLE) {
        uint8_t r7[4];
        r7[0] = spi_xfer(0xFF);
        r7[1] = spi_xfer(0xFF);
        r7[2] = spi_xfer(0xFF);
        r7[3] = spi_xfer(0xFF);
        sd_v2 = (r7[2] == 0x01) && (r7[3] == 0xAA);
    } else {
        sd_v2 = 0;
    }

    // Init loop.
    uint32_t tries = 2000u;
    do {
        if (sd_send_acmd41(sd_v2, &r1) != 0) {
            g_sd_err = SD_E_ACMD41;
            sd_deselect();
            return -1;
        }
        if (r1 == R1_OK)
            break;
    } while (tries--);

    if (r1 != R1_OK) {
        g_sd_err = SD_E_ACMD41;
        sd_deselect();
        return -1;
    }

    // Read OCR to determine SDHC/SDXC.
    if (sd_send_cmd(CMD58, 0, 0xFF, &r1) != 0 || r1 != R1_OK) {
        g_sd_err = SD_E_CMD58;
        sd_deselect();
        return -1;
    }
    uint8_t ocr0 = spi_xfer(0xFF);
    (void)spi_xfer(0xFF);
    (void)spi_xfer(0xFF);
    (void)spi_xfer(0xFF);
    g_sd_sdhc = (ocr0 & 0x40) ? 1 : 0;

    if (!g_sd_sdhc) {
        // SDSC: set block length to 512.
        if (sd_send_cmd(CMD16, 512u, 0xFF, &r1) != 0 || r1 != R1_OK) {
            g_sd_err = SD_E_CMD16;
            sd_deselect();
            return -1;
        }
    }

    sd_deselect();
    g_sd_inited = 1;
    g_sd_err = SD_E_NONE;
    return 0;
}

int sdcard_read_block(uint32_t lba, uint8_t out512[512]) {
    if (sdcard_init() != 0)
        return -1;

    uint32_t arg = g_sd_sdhc ? lba : (lba * 512u);

    sd_select();

    uint8_t r1;
    if (sd_send_cmd(CMD17, arg, 0xFF, &r1) != 0 || r1 != R1_OK) {
        g_sd_err = SD_E_CMD17;
        sd_deselect();
        return -1;
    }

    // Wait for data token 0xFE.
    uint32_t tries = 0xFFFFu;
    uint8_t token;
    do {
        token = spi_xfer(0xFF);
        if (token == 0xFE)
            break;
    } while (tries--);

    if (token != 0xFE) {
        g_sd_err = SD_E_TOKEN;
        sd_deselect();
        return -1;
    }

    for (int i = 0; i < 512; ++i)
        out512[i] = spi_xfer(0xFF);
    (void)spi_xfer(0xFF);
    (void)spi_xfer(0xFF);

    sd_deselect();
    g_sd_err = SD_E_NONE;
    return 0;
}
