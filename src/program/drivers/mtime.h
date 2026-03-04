#ifndef MTIME_H
#define MTIME_H

#include <stdint.h>

#define IO_BASE_ADDR           0x400000u

#define IO_MTIME_LO_OFFSET     0x60u
#define IO_MTIME_HI_OFFSET     0x64u
#define IO_MTIMECMP_LO_OFFSET  0x68u
#define IO_MTIMECMP_HI_OFFSET  0x6Cu

static inline volatile uint32_t* mtime_lo_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_MTIME_LO_OFFSET);
}

static inline volatile uint32_t* mtime_hi_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_MTIME_HI_OFFSET);
}

static inline volatile uint32_t* mtimecmp_lo_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_MTIMECMP_LO_OFFSET);
}

static inline volatile uint32_t* mtimecmp_hi_reg(void) {
    return (volatile uint32_t*)(IO_BASE_ADDR + IO_MTIMECMP_HI_OFFSET);
}

static inline uint64_t mtime_read(void) {
    uint32_t hi, lo;
    do {
        hi = *mtime_hi_reg();
        lo = *mtime_lo_reg();
    } while (hi != *mtime_hi_reg());
    return ((uint64_t)hi << 32) | lo;
}

static inline void mtimecmp_write(uint64_t val) {
    *mtimecmp_hi_reg() = 0xFFFFFFFF;
    *mtimecmp_lo_reg() = (uint32_t)val;
    *mtimecmp_hi_reg() = (uint32_t)(val >> 32);
}

#endif /* MTIME_H */
