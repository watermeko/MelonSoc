#include "lcd.h"

void lcd_clear(uint16_t color) {
    volatile uint16_t *fb = lcd_fb();
    for (uint32_t i = 0; i < (uint32_t)LCD_WIDTH * LCD_HEIGHT; ++i)
        fb[i] = color;
}

void lcd_fill(uint16_t color) {
    lcd_clear(color);
}

void lcd_set_pixel(uint32_t x, uint32_t y, uint16_t color) {
    if (x >= LCD_WIDTH || y >= LCD_HEIGHT)
        return;
    lcd_fb()[y * LCD_WIDTH + x] = color;
}

// 16 equal-width RGB565 bit bars matching the reference RTL pattern.
void lcd_colorbar(void) {
    static const uint16_t bars[16] = {
        0x8000, 0x4000, 0x2000, 0x1000, 0x0800,
        0x0400, 0x0200, 0x0100, 0x0080, 0x0040, 0x0020,
        0x0010, 0x0008, 0x0004, 0x0002, 0x0001
    };
    const uint32_t bar_w = LCD_WIDTH / 16;  // 30 px per bar
    volatile uint16_t *fb = lcd_fb();
    for (uint32_t y = 0; y < LCD_HEIGHT; ++y) {
        for (uint32_t x = 0; x < LCD_WIDTH; ++x) {
            uint32_t b = x / bar_w;
            if (b > 15) b = 15;
            fb[y * LCD_WIDTH + x] = bars[b];
        }
    }
}
