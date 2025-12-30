#ifndef SDCARD_H
#define SDCARD_H

#include <stdint.h>

int sdcard_init(void);
int sdcard_read_block(uint32_t lba, uint8_t out512[512]);
uint8_t sdcard_last_error(void);

#endif /* SDCARD_H */
