#ifndef MSIP_H
#define MSIP_H

#include <stdint.h>

/* Machine Software Interrupt Pending (MSIP) MMIO 驱动
 *
 * 寄存器地址: 0x400070
 *   写 bit[0] = 1 → 置位软件中断 (CPU mip.MSIP = 1)
 *   写 bit[0] = 0 → 清除软件中断 (CPU mip.MSIP = 0)
 *   读           → {31'b0, msip_reg}
 *
 * 使用方法:
 *   1. csrs mie, (1<<3)          ; 使能 MSIE
 *   2. csrs mstatus, (1<<3)      ; 全局中断开
 *   3. msip_trigger()            ; 触发软件中断
 *   4. trap handler 中: msip_clear() ; 清除中断源
 */

#define IO_MSIP_ADDR  0x400070u

static inline volatile uint32_t* msip_mmio_reg(void) {
    return (volatile uint32_t*)IO_MSIP_ADDR;
}

static inline void msip_trigger(void) {
    *msip_mmio_reg() = 1u;
}

static inline void msip_clear(void) {
    *msip_mmio_reg() = 0u;
}

static inline uint32_t msip_read(void) {
    return *msip_mmio_reg();
}

#endif /* MSIP_H */
