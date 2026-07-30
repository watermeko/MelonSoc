#ifndef BOOT_IMAGE_H
#define BOOT_IMAGE_H

#include <stdint.h>

#define BOOT_IMAGE_MAGIC       0x5244444Du /* "MDDR" in little endian */
#define BOOT_IMAGE_HEADER_SIZE 12u
#define BOOT_IMAGE_LOAD_ADDR   0x80000000u
#define BOOT_IMAGE_LOAD_LIMIT  0x80100000u /* LCD framebuffer starts here */

enum boot_image_error {
    BOOT_IMAGE_OK = 0,
    BOOT_IMAGE_ERR_MAGIC = -1,
    BOOT_IMAGE_ERR_RANGE = -2,
    BOOT_IMAGE_ERR_FILE_SIZE = -3,
};

int boot_image_parse_header(const uint8_t *header, uint32_t dst,
                            uint32_t *text_size, uint32_t *data_size,
                            uint32_t *payload_size);
int boot_image_validate_file_size(uint32_t file_size, uint32_t text_size,
                                  uint32_t data_size);

#endif /* BOOT_IMAGE_H */
