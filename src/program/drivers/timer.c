#include "timer.h"

static uint32_t g_timer_ticks_per_sec;

static inline void timer_write_ctrl(uint32_t value) {
    *timer_ctrl_reg() = value;
}

uint32_t timer_ticks_per_sec(void) {
    return g_timer_ticks_per_sec;
}

uint32_t timer_get_count(void) {
    return *timer_count_reg();
}

void timer_init_1mhz(uint32_t clk_hz) {
    uint32_t divider = clk_hz / 1000000u;
    if (divider == 0)
        divider = 1;

    uint32_t presc = divider - 1u;
    g_timer_ticks_per_sec = clk_hz / divider;

    timer_write_ctrl(TIMER_CTRL_SOFT_RESET);
    *timer_presc_reg() = presc;
    *timer_count_reg() = 0;
    timer_write_ctrl(TIMER_CTRL_EN | TIMER_CTRL_PRESC_EN);
}

void timer_delay_ticks(uint32_t ticks) {
    uint32_t start = timer_get_count();
    while ((uint32_t)(timer_get_count() - start) < ticks) {
        ;
    }
}

static uint32_t mul_div_u32(uint32_t a, uint32_t b, uint32_t div) {
    if (div == 0)
        return 0;
    return (uint32_t)(((unsigned long long)a * (unsigned long long)b) / (unsigned long long)div);
}

void timer_delay_us(uint32_t us) {
    uint32_t tps = timer_ticks_per_sec();
    if (tps == 0) {
        timer_delay_ticks(us);
        return;
    }
    timer_delay_ticks(mul_div_u32(us, tps, 1000000u));
}

void timer_delay_ms(uint32_t ms) {
    uint32_t tps = timer_ticks_per_sec();
    if (tps == 0) {
        timer_delay_ticks(ms * 1000u);
        return;
    }
    timer_delay_ticks(mul_div_u32(ms, tps, 1000u));
}

void timer_delay_s(uint32_t s) {
    uint32_t tps = timer_ticks_per_sec();
    if (tps == 0) {
        while (s--)
            timer_delay_ticks(1000000u);
        return;
    }

    while (s) {
        uint32_t chunk = s;
        if (tps != 0 && chunk > (0xFFFFFFFFu / tps))
            chunk = 0xFFFFFFFFu / tps;
        timer_delay_ticks(chunk * tps);
        s -= chunk;
    }
}

