#ifndef CLINT_H
#define CLINT_H

#include <stdint.h>

/*
 * Standard SiFive CLINT (Core Local Interruptor) driver for RV32, 1 hart.
 *
 * Register layout (offsets from CLINT_BASE = 0x400000):
 *   0x0000  MSIP[0]         — Machine Software Interrupt Pending (hart 0)
 *   0x4000  MTIMECMP[0].lo  — Machine Timer Compare (hart 0), low 32 bits
 *   0x4004  MTIMECMP[0].hi  — Machine Timer Compare (hart 0), high 32 bits
 *   0xBFF8  MTIME.lo        — Machine Timer (read-only), low 32 bits
 *   0xBFFC  MTIME.hi        — Machine Timer (read-only), high 32 bits
 *
 * Usage:
 *   // Timer interrupt
 *   clint_set_mtimecmp(clint_get_mtime() + 100000);
 *   csrs mie, (1 << 7);      // enable MTIE
 *   csrs mstatus, (1 << 3);  // global interrupt enable
 *
 *   // Software interrupt (inter-processor / self-IPI)
 *   clint_set_msip();
 *   // ... in trap handler after handling:
 *   clint_clear_msip();
 */

#define CLINT_BASE          0x400000u

#define CLINT_MSIP_OFFSET       0x0000u
#define CLINT_MTIMECMP_OFFSET   0x4000u
#define CLINT_MTIME_OFFSET      0xBFF8u

/* ---- low-level MMIO accessors ---- */

static inline volatile uint32_t *clint_mmio(uint32_t offset) {
    return (volatile uint32_t *)(CLINT_BASE + offset);
}

/* ---- Machine Timer (mtime / mtimecmp) ---- */

static inline uint64_t clint_get_mtime(void) {
    uint32_t hi, lo;
    do {
        hi = *clint_mmio(CLINT_MTIME_OFFSET + 4);
        lo = *clint_mmio(CLINT_MTIME_OFFSET);
    } while (hi != *clint_mmio(CLINT_MTIME_OFFSET + 4));
    return ((uint64_t)hi << 32) | lo;
}

static inline void clint_set_mtimecmp(uint64_t val) {
    /* per SiFive spec: write lo first, then hi — the hi write
       latches the full 64-bit compare value. */
    *clint_mmio(CLINT_MTIMECMP_OFFSET)     = (uint32_t)(val);
    *clint_mmio(CLINT_MTIMECMP_OFFSET + 4) = (uint32_t)(val >> 32);
}

/* ---- Machine Software Interrupt (MSIP) ---- */

static inline void clint_set_msip(void) {
    *clint_mmio(CLINT_MSIP_OFFSET) = 1u;
}

static inline void clint_clear_msip(void) {
    *clint_mmio(CLINT_MSIP_OFFSET) = 0u;
}

#endif /* CLINT_H */
