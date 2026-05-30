#ifndef FATBOOT_H
#define FATBOOT_H

#include <stdint.h>

int fatboot_load(uint32_t dst, uint32_t *size_out);

#endif
