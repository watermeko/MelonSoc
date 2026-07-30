#include <stdint.h>

#include "test_shift.h"

int printf(const char *fmt, ...);
int puts(const char *s);

static uint32_t run_srai16(uint32_t value) {
    asm volatile(
        ".option push\n"
        ".option norvc\n"
        "srai %0, %0, 16\n"
        ".option pop\n"
        : "+r"(value));
    return value;
}

static uint32_t run_srli16(uint32_t value) {
    asm volatile(
        ".option push\n"
        ".option norvc\n"
        "srli %0, %0, 16\n"
        ".option pop\n"
        : "+r"(value));
    return value;
}

static uint32_t run_sra(uint32_t value, uint32_t amount) {
    asm volatile(
        ".option push\n"
        ".option norvc\n"
        "sra %0, %0, %1\n"
        ".option pop\n"
        : "+r"(value)
        : "r"(amount));
    return value;
}

static uint32_t run_c_srai16(uint32_t value) {
    register uint32_t result asm("a0") = value;
    asm volatile(
        ".option push\n"
        ".option rvc\n"
        "c.srai a0, 16\n"
        ".option pop\n"
        : "+r"(result));
    return result;
}

__attribute__((noinline))
static uint16_t crc16_uint16(const uint8_t *data, uint32_t size) {
    uint16_t crc = 0;

    for (uint32_t i = 0; i < size; ++i) {
        crc ^= (uint16_t)data[i] << 8;
        for (int bit = 0; bit < 8; ++bit)
            crc = (crc & 0x8000u) ? (uint16_t)((crc << 1) ^ 0x1021u)
                                  : (uint16_t)(crc << 1);
    }
    return crc;
}

static int check_u32(const char *name, uint32_t actual, uint32_t expected) {
    if (actual == expected) {
        printf("[OK] %s = 0x%x\n", name, (unsigned)actual);
        return 1;
    }

    printf("[FAIL] %s expected=0x%x actual=0x%x\n",
           name, (unsigned)expected, (unsigned)actual);
    return 0;
}

void shell_test_shift(const char *arg) {
    static const uint8_t crc_text[] = "123456789";
    static const uint8_t crc_one[] = {0x01};
    int passed = 1;

    if (arg && *arg) {
        puts("Usage: test-shift");
        return;
    }

    puts("--- Shift and narrow integer test ---");
    passed &= check_u32("SRAI 0x80000000 >> 16",
                        run_srai16(0x80000000u), 0xFFFF8000u);
    passed &= check_u32("SRLI 0x80000000 >> 16",
                        run_srli16(0x80000000u), 0x00008000u);
    passed &= check_u32("SRA 0x80000000 >> 16",
                        run_sra(0x80000000u, 16u), 0xFFFF8000u);
    passed &= check_u32("C.SRAI 0x80000000 >> 16",
                        run_c_srai16(0x80000000u), 0xFFFF8000u);
    passed &= check_u32("uint16 CRC 0x01",
                        crc16_uint16(crc_one, sizeof(crc_one)), 0x1021u);
    passed &= check_u32("uint16 CRC 123456789",
                        crc16_uint16(crc_text, sizeof(crc_text) - 1u), 0x31C3u);

    puts(passed ? "--- SHIFT TEST PASSED ---" : "--- SHIFT TEST FAILED ---");
}
