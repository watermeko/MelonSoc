#ifndef XMODEM_H
#define XMODEM_H

#include <stdint.h>

int xmodem_load_boot_image(uint32_t dst, uint32_t *size_out);

#endif /* XMODEM_H */
