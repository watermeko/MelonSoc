#include "gpio.h"

void gpio_init(void) {
    gpio_set_leds(0);
}

void gpio_set_leds(uint8_t value) {
    *gpio_leds_reg() = value;
}

uint8_t gpio_get_leds(void) {
    return (uint8_t)(*gpio_leds_reg() & 0x3Fu);
}
