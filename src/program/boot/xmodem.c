#include "xmodem.h"

#include "boot_image.h"
#include "timer.h"
#include "uart.h"

#define XMODEM_SOH                 0x01u
#define XMODEM_EOT                 0x04u
#define XMODEM_ACK                 0x06u
#define XMODEM_NAK                 0x15u
#define XMODEM_CAN                 0x18u
#define XMODEM_CRC_REQUEST         'C'
#define XMODEM_BLOCK_SIZE          128u
#define XMODEM_TIMEOUT_TICKS       1000000u
#define XMODEM_MAX_RETRIES         16u

enum xmodem_result {
    XMODEM_OK = 0,
    XMODEM_ERR_TIMEOUT = -1,
    XMODEM_ERR_CANCELLED = -2,
    XMODEM_ERR_PROTOCOL = -3,
    XMODEM_ERR_IMAGE = -4,
    XMODEM_ERR_UART = -5,
    XMODEM_ERR_BLOCK_NUMBER = -6,
    XMODEM_ERR_CRC = -7,
};

static uint16_t crc16_ccitt(const uint8_t *data, uint32_t size) {
    uint32_t crc = 0;

    for (uint32_t i = 0; i < size; ++i) {
        crc ^= (uint32_t)data[i] << 8;
        for (int bit = 0; bit < 8; ++bit) {
            if (crc & 0x8000u)
                crc = (crc << 1) ^ 0x1021u;
            else
                crc <<= 1;
            crc &= 0xFFFFu;
        }
    }
    return (uint16_t)crc;
}

static int getc_timeout(uint32_t timeout_ticks) {
    uint32_t start = timer_get_count();

    for (;;) {
        uint32_t status = uart_get_status();
        if (status & UART_STATUS_RX_OVERRUN) {
            uart_clear_status(UART_STATUS_RX_OVERRUN);
            return XMODEM_ERR_UART;
        }
        if (status & UART_STATUS_RX_FRAMEERR) {
            uart_clear_status(UART_STATUS_RX_FRAMEERR);
            return XMODEM_ERR_UART;
        }
        if (status & UART_STATUS_RX_VALID) {
            int byte = uart_getc_nonblocking();
            if (byte >= 0)
                return byte;
        }
        if ((uint32_t)(timer_get_count() - start) >= timeout_ticks)
            return XMODEM_ERR_TIMEOUT;
    }
}

static void cancel_transfer(void) {
    uart_putc_blocking(XMODEM_CAN);
    uart_putc_blocking(XMODEM_CAN);
}

static int receive_block(uint8_t data[XMODEM_BLOCK_SIZE], uint8_t *block_no) {
    int block = getc_timeout(XMODEM_TIMEOUT_TICKS);
    int inverse = getc_timeout(XMODEM_TIMEOUT_TICKS);
    uint16_t received_crc;
    uint16_t calculated_crc;

    if (block < 0 || inverse < 0)
        return block < 0 ? block : inverse;

    for (uint32_t i = 0; i < XMODEM_BLOCK_SIZE; ++i) {
        int byte = getc_timeout(XMODEM_TIMEOUT_TICKS);
        if (byte < 0)
            return byte;
        data[i] = (uint8_t)byte;
    }

    int crc_hi = getc_timeout(XMODEM_TIMEOUT_TICKS);
    int crc_lo = getc_timeout(XMODEM_TIMEOUT_TICKS);
    if (crc_hi < 0 || crc_lo < 0)
        return crc_hi < 0 ? crc_hi : crc_lo;

    if (((uint8_t)block ^ (uint8_t)inverse) != 0xFFu)
        return XMODEM_ERR_BLOCK_NUMBER;

    received_crc = ((uint16_t)(uint8_t)crc_hi << 8) | (uint8_t)crc_lo;
    calculated_crc = crc16_ccitt(data, XMODEM_BLOCK_SIZE);
    if (received_crc != calculated_crc)
        return XMODEM_ERR_CRC;

    *block_no = (uint8_t)block;
    return XMODEM_OK;
}

static int store_block(const uint8_t data[XMODEM_BLOCK_SIZE], uint32_t dst,
                       uint32_t *stream_offset, uint8_t *header,
                       int *header_ready, uint32_t *image_size) {
    uint32_t offset = *stream_offset;

    if (*header_ready && offset >= *image_size)
        return XMODEM_ERR_IMAGE;

    for (uint32_t i = 0; i < XMODEM_BLOCK_SIZE; ++i) {
        uint32_t image_offset = offset + i;

        if (image_offset < BOOT_IMAGE_HEADER_SIZE) {
            header[image_offset] = data[i];
            if (image_offset + 1u == BOOT_IMAGE_HEADER_SIZE) {
                uint32_t text_size;
                uint32_t data_size;
                uint32_t payload_size;
                int rc = boot_image_parse_header(
                    header, dst, &text_size, &data_size, &payload_size);
                if (rc != BOOT_IMAGE_OK)
                    return XMODEM_ERR_IMAGE;
                (void)text_size;
                (void)data_size;
                *image_size = BOOT_IMAGE_HEADER_SIZE + payload_size;
                *header_ready = 1;
            }
        }
        else if (*header_ready && image_offset < *image_size) {
            volatile uint8_t *out = (volatile uint8_t *)(uintptr_t)
                (dst + image_offset - BOOT_IMAGE_HEADER_SIZE);
            *out = data[i];
        }
        else if (*header_ready && image_offset >= *image_size &&
                 image_offset < *image_size + XMODEM_BLOCK_SIZE) {
            /* The final XMODEM block may contain 0x1a padding only. */
            if (data[i] != 0x1Au)
                return XMODEM_ERR_IMAGE;
        }
    }

    *stream_offset = offset + XMODEM_BLOCK_SIZE;
    return XMODEM_OK;
}

int xmodem_load_boot_image(uint32_t dst, uint32_t *size_out) {
    uint8_t data[XMODEM_BLOCK_SIZE];
    uint8_t header[BOOT_IMAGE_HEADER_SIZE];
    uint8_t expected_block = 1;
    uint32_t stream_offset = 0;
    uint32_t image_size = 0;
    int header_ready = 0;
    int sync_started = 0;
    uint32_t sync_retries = 0;
    uint32_t block_retries = 0;

    if (!size_out)
        return XMODEM_ERR_IMAGE;

    uart_clear_status(UART_STATUS_RX_OVERRUN | UART_STATUS_RX_FRAMEERR);

    for (;;) {
        int control;

        if (!sync_started && sync_retries < XMODEM_MAX_RETRIES) {
            uart_putc_blocking(XMODEM_CRC_REQUEST);
            ++sync_retries;
        }

        control = getc_timeout(XMODEM_TIMEOUT_TICKS);
        if (control == XMODEM_ERR_TIMEOUT) {
            if (sync_retries >= XMODEM_MAX_RETRIES) {
                cancel_transfer();
                return XMODEM_ERR_TIMEOUT;
            }
            continue;
        }
        if (control == XMODEM_ERR_UART) {
            if (++block_retries >= XMODEM_MAX_RETRIES) {
                cancel_transfer();
                return XMODEM_ERR_UART;
            }
            uart_putc_blocking(XMODEM_NAK);
            continue;
        }
        if (control == XMODEM_CAN) {
            int second = getc_timeout(XMODEM_TIMEOUT_TICKS);
            if (second == XMODEM_CAN)
                return XMODEM_ERR_CANCELLED;
            continue;
        }
        if (control == XMODEM_EOT) {
            if (!header_ready || stream_offset < image_size) {
                cancel_transfer();
                return XMODEM_ERR_IMAGE;
            }
            uart_putc_blocking(XMODEM_ACK);
            *size_out = image_size - BOOT_IMAGE_HEADER_SIZE;
            return XMODEM_OK;
        }
        if (control != XMODEM_SOH) {
            if (++block_retries >= XMODEM_MAX_RETRIES) {
                cancel_transfer();
                return XMODEM_ERR_PROTOCOL;
            }
            continue;
        }

        sync_started = 1;

        uint8_t block_no = 0;
        int rc = receive_block(data, &block_no);
        if (rc != XMODEM_OK) {
            if (++block_retries >= XMODEM_MAX_RETRIES) {
                cancel_transfer();
                return rc;
            }
            uart_putc_blocking(XMODEM_NAK);
            continue;
        }

        if (block_no == (uint8_t)(expected_block - 1u)) {
            uart_putc_blocking(XMODEM_ACK);
            block_retries = 0;
            continue;
        }
        if (block_no != expected_block) {
            if (++block_retries >= XMODEM_MAX_RETRIES) {
                cancel_transfer();
                return XMODEM_ERR_PROTOCOL;
            }
            uart_putc_blocking(XMODEM_NAK);
            continue;
        }

        rc = store_block(data, dst, &stream_offset, header,
                         &header_ready, &image_size);
        if (rc != XMODEM_OK) {
            cancel_transfer();
            return rc;
        }

        ++expected_block;
        block_retries = 0;
        uart_putc_blocking(XMODEM_ACK);
    }
}
