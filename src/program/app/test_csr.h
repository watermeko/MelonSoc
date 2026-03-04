#ifndef TEST_CSR_H
#define TEST_CSR_H

#include <stdint.h>

static inline uint32_t read_mscratch(void){
    uint32_t value;
    asm volatile("csrr %0, mscratch" : "=r"(value));
    return value;
}

static inline void write_mscratch(uint32_t value){
    asm volatile("csrw mscratch, %0" :: "r"(value));
}

static inline uint32_t read_mtvec(void){
    uint32_t value;
    asm volatile("csrr %0, mtvec" : "=r"(value));
    return value;
}

static inline void set_mtvec_bits(uint32_t mask){
    asm volatile("csrs mtvec, %0" :: "r"(mask));
}

static inline void clear_mtvec_bits(uint32_t mask){
    asm volatile("csrc mtvec, %0" :: "r"(mask));
}

extern volatile uint32_t trap_cause_val;
extern volatile int trap_hit_flag;

#ifdef __riscv
#define INTERRUPT_ATTR __attribute__((interrupt("machine"), aligned(4)))
#else
#define INTERRUPT_ATTR
#endif

INTERRUPT_ATTR void trap_handler(void);
#endif
