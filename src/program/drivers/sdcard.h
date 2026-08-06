#ifndef SDCARD_H
#define SDCARD_H

#include <stdint.h>

int sdcard_init(void);
int sdcard_read_block(uint32_t lba, uint8_t out512[512]);
uint8_t sdcard_last_error(void);
uint32_t sdcard_last_status(void);
uint32_t sdcard_last_debug(void);
uint32_t sdcard_last_crc(void);
uint32_t sdcard_ocr(void);
int sdcard_is_high_capacity(void);

#endif /* SDCARD_H */
