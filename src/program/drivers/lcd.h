#ifndef LCD_H
#define LCD_H

#include <stdint.h>

// RGB565 480x272 LCD framebuffer reserved in DDR (see linker_ddr.ld).
// The hardware LCD DMA streams this region to the panel continuously.
#define LCD_WIDTH  480
#define LCD_HEIGHT 272
#define LCD_FB_BASE 0x80100000u   // fixed framebuffer base (256 KiB region)

static inline volatile uint16_t *lcd_fb(void) {
    return (volatile uint16_t *)(uintptr_t)LCD_FB_BASE;
}

// Pack an 8-bit RGB triplet into RGB565.
static inline uint16_t lcd_rgb565(uint8_t r, uint8_t g, uint8_t b) {
    return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}

void lcd_clear(uint16_t color);
void lcd_fill(uint16_t color);
void lcd_set_pixel(uint32_t x, uint32_t y, uint16_t color);
void lcd_colorbar(void);

#endif