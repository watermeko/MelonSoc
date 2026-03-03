#ifndef GPIO_H
#define GPIO_H

#include <stdint.h>

#define IO_BASE_ADDR        0x400000u
#define IO_LEDS_OFFSET      0x4u

static inline volatile uint32_t* gpio_leds_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_LEDS_OFFSET);
}

void gpio_init(void);
void gpio_set_leds(uint8_t value);
uint8_t gpio_get_leds(void);

#endif /* GPIO_H */
