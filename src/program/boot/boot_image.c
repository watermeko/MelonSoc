#include "boot_image.h"

static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

int boot_image_parse_header(const uint8_t *header, uint32_t dst,
                            uint32_t *text_size, uint32_t *data_size,
                            uint32_t *payload_size) {
    uint32_t text;
    uint32_t data;
    uint32_t available;

    if (!header || !text_size || !data_size || !payload_size)
        return BOOT_IMAGE_ERR_MAGIC;

    if (rd32(&header[0]) != BOOT_IMAGE_MAGIC)
        return BOOT_IMAGE_ERR_MAGIC;

    if (dst < BOOT_IMAGE_LOAD_ADDR || dst >= BOOT_IMAGE_LOAD_LIMIT)
        return BOOT_IMAGE_ERR_RANGE;

    text = rd32(&header[4]);
    data = rd32(&header[8]);
    available = BOOT_IMAGE_LOAD_LIMIT - dst;

    if (text > available || data > available - text)
        return BOOT_IMAGE_ERR_RANGE;

    *text_size = text;
    *data_size = data;
    *payload_size = text + data;
    return BOOT_IMAGE_OK;
}

int boot_image_validate_file_size(uint32_t file_size, uint32_t text_size,
                                  uint32_t data_size) {
    uint32_t payload_size;

    if (file_size < BOOT_IMAGE_HEADER_SIZE)
        return BOOT_IMAGE_ERR_FILE_SIZE;

    payload_size = file_size - BOOT_IMAGE_HEADER_SIZE;
    if (text_size > payload_size)
        return BOOT_IMAGE_ERR_FILE_SIZE;

    return data_size == payload_size - text_size
               ? BOOT_IMAGE_OK
               : BOOT_IMAGE_ERR_FILE_SIZE;
}
