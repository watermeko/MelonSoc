#ifndef TIMER_H
#define TIMER_H

#include <stdint.h>

#define IO_BASE_ADDR           0x400000u

#define IO_TIMER_CTRL_OFFSET   0x30u
#define IO_TIMER_PRESC_OFFSET  0x34u
#define IO_TIMER_COUNT_OFFSET  0x38u
#define IO_TIMER_CMP_OFFSET    0x3Cu
#define IO_TIMER_PERIOD_OFFSET 0x40u
#define IO_TIMER_STATUS_OFFSET 0x44u

#define TIMER_CTRL_EN          (1u << 0)
#define TIMER_CTRL_ARMED       (1u << 1)
#define TIMER_CTRL_PERIODIC    (1u << 2)
#define TIMER_CTRL_PRESC_EN    (1u << 3)
#define TIMER_CTRL_IRQ_EN      (1u << 8)
#define TIMER_CTRL_SOFT_RESET  (1u << 31)

#define TIMER_STATUS_PENDING   (1u << 0)

static inline volatile uint32_t* timer_ctrl_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_TIMER_CTRL_OFFSET);
}

static inline volatile uint32_t* timer_presc_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_TIMER_PRESC_OFFSET);
}

static inline volatile uint32_t* timer_count_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_TIMER_COUNT_OFFSET);
}

static inline volatile uint32_t* timer_cmp_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_TIMER_CMP_OFFSET);
}

static inline volatile uint32_t* timer_period_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_TIMER_PERIOD_OFFSET);
}

static inline volatile uint32_t* timer_status_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_TIMER_STATUS_OFFSET);
}

void timer_init_1mhz(uint32_t clk_hz);
uint32_t timer_ticks_per_sec(void);

uint32_t timer_get_count(void);
void timer_delay_ticks(uint32_t ticks);
void timer_delay_us(uint32_t us);
void timer_delay_ms(uint32_t ms);
void timer_delay_s(uint32_t s);

#endif /* TIMER_H */

