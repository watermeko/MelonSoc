#include <stdarg.h>
#include <stdint.h>
#include "uart.h"
#include "gpio.h"
#include "i2c.h"
#include "spi.h"
#include "sdcard.h"
#include "timer.h"
#include "mtime.h"
#include "ddr.h"
#include "test_csr.h"

void raystones_run(void);

void print_hex_digits(unsigned int val, int nbdigits);
static int str_equals(const char *a, const char *b);

// Performance counter functions
static inline uint64_t rdcycle(void) {
    uint32_t lo, hi, hi_check;
    do {
        asm volatile("rdcycleh %0" : "=r"(hi));
        asm volatile("rdcycle %0" : "=r"(lo));
        asm volatile("rdcycleh %0" : "=r"(hi_check));
    } while (hi != hi_check);
    return ((uint64_t)hi << 32) | lo;
}

void print_string(const char* s) {
   for(const char* p = s; *p; ++p) {
      putchar(*p);
   }
}

int puts(const char* s) {
   print_string(s);
   putchar('\n');
   return 1;
}

void print_dec(int val) {
   char buffer[255];
   char *p = buffer;
   if(val < 0) {
      putchar('-');
      print_dec(-val);
      return;
   }
   while (val || p == buffer) {
      *(p++) = val % 10;
      val = val / 10;
   }
   while (p != buffer) {
      putchar('0' + *(--p));
   }
}

void print_hex(unsigned int val) {
   print_hex_digits(val, 8);
}

void print_hex_digits(unsigned int val, int nbdigits) {
   for (int i = (4*nbdigits)-4; i >= 0; i -= 4) {
      putchar("0123456789ABCDEF"[(val >> i) % 16]);
   }
}

int printf(const char *fmt,...)
{
    va_list ap;

    for(va_start(ap, fmt);*fmt;fmt++)
    {
        if(*fmt=='%')
        {
            fmt++;
                 if(*fmt=='s') print_string(va_arg(ap,char *));
            else if(*fmt=='x') print_hex(va_arg(ap,int));
            else if(*fmt=='d') print_dec(va_arg(ap,int));
            else if(*fmt=='u') {
                // Print unsigned decimal (simple implementation)
                unsigned int uval = va_arg(ap, unsigned int);
                if (uval == 0) {
                    putchar('0');
                } else {
                    char buffer[12];
                    int i = 0;
                    while (uval > 0) {
                        buffer[i++] = (uval % 10) + '0';
                        uval /= 10;
                    }
                    while (i > 0) {
                        putchar(buffer[--i]);
                    }
                }
            }
            else if(*fmt=='l' && *(fmt+1)=='l' && *(fmt+2)=='u') {
                // Print unsigned long long (64-bit)
                fmt += 2;
                unsigned long long ullval = va_arg(ap, unsigned long long);
                if (ullval == 0) {
                    putchar('0');
                } else {
                    char buffer[24];
                    int i = 0;
                    while (ullval > 0) {
                        buffer[i++] = (ullval % 10) + '0';
                        ullval /= 10;
                    }
                    while (i > 0) {
                        putchar(buffer[--i]);
                    }
                }
            }
            else if(*fmt=='c') putchar(va_arg(ap,int));
            else putchar(*fmt);
        }
        else putchar(*fmt);
    }

    va_end(ap);

    return 0;
}

static void shell_help(void) {
    puts("Commands:");
    puts("  help               - show this help");
    puts("  led <6-bit-bin>    - set LEDs, e.g. led 101010");
    puts("  blink <seconds>    - alternate LEDs every N seconds");
    puts("  print <text>       - print text");
    puts("  i2c_scan           - scan I2C 7-bit addresses");
    puts("  sdcard_rd <skip> <count> - read sector 0 and hex dump bytes");
    puts("  ddr probe|rd|wr    - access DDR via DDR3 APP MMIO");
    puts("  raystones          - run the raystones benchmark");
    puts("  test-m             - test M extension (multiply/divide)");
    puts("  test-csr           - test CSRs and trap handling");
    puts("  test-irq           - test asynchronous hardware interrupts");
    puts("  test-mtime         - read and display machine timer");
}

static void shell_set_leds(const char *arg) {
    if (arg == 0 || *arg == 0) {
        puts("Usage: led <6-bit-binary>");
        return;
    }

    uint8_t value = 0;
    int count = 0;
    while (arg[count] == '0' || arg[count] == '1') {
        value = (value << 1) | (arg[count] - '0');
        count++;
        if (count > 6)
            break;
    }

    if (count != 6 || (arg[count] != 0 && arg[count] != ' ')) {
        puts("Error: provide exactly 6 binary digits, e.g. led 101010");
        return;
    }

    gpio_set_leds(value);
    uint8_t actual = gpio_get_leds();
    printf("LEDs set to 0b");
    for (int bit = 5; bit >= 0; --bit)
        putchar(((value >> bit) & 1) ? '1' : '0');
    printf(" (readback 0b");
    for (int bit = 5; bit >= 0; --bit)
        putchar(((actual >> bit) & 1) ? '1' : '0');
    puts(")");
}

static void shell_print_text(const char *arg) {
    if (!arg || *arg == 0) {
        puts("Usage: print <text>");
        return;
    }
    puts(arg);
}

static void shell_run_raystones(const char *arg) {
    if (arg && *arg) {
        puts("Usage: raystones");
        return;
    }
    raystones_run();
}

static void shell_test_irq(const char *arg) {
    if (arg && *arg) {
        puts("Usage: test-irq");
        return;
    }

    printf("--- Timer Peripheral (External) Interrupt Test Start ---\n");

    uint32_t trap_addr = (uint32_t)&trap_handler;
    asm volatile("csrw mtvec, %0" :: "r"(trap_addr));
    
    trap_hit_flag = 0;
    trap_cause_val = 0;

    asm volatile("csrs mie, %0" :: "r"(1 << 11));

    uint32_t current_time = timer_get_count();
    *timer_cmp_reg() = current_time + 50000;
    *timer_ctrl_reg() = TIMER_CTRL_EN | TIMER_CTRL_ARMED | TIMER_CTRL_IRQ_EN;

    asm volatile("csrs mstatus, %0" :: "r"(1 << 3));

    printf("Waiting for timer interrupt...\n");

    int timeout = 0;
    while (!trap_hit_flag) {
        timeout++;
        if (timeout > 1000000) {
            printf("[FAIL] Timeout waiting for interrupt.\n");
            break;
        }
    }

    asm volatile("csrc mstatus, %0" :: "r"(1 << 3));
    asm volatile("csrc mie, %0" :: "r"(1 << 11));

    if (trap_hit_flag) {
        if (trap_cause_val == 0x8000000B) {
            printf("[OK] Timer peripheral interrupt correctly triggered and handled.\n");
            printf("--- TIMER PERIPHERAL TEST PASSED! ---\n");
        } else {
            printf("[FAIL] Interrupt triggered but wrong cause: 0x%x (expected 0x8000000B)\n", trap_cause_val);
        }
    }
}

static void shell_test_mtime(const char *arg) {
    if (arg && *arg) {
        puts("Usage: test-mtime");
        return;
    }

    printf("--- Machine Timer (mtime) Interrupt Test Start ---\n");

    uint32_t trap_addr = (uint32_t)&trap_handler;
    asm volatile("csrw mtvec, %0" :: "r"(trap_addr));
    
    trap_hit_flag = 0;
    trap_cause_val = 0;

    asm volatile("csrs mie, %0" :: "r"(1 << 7));

    uint64_t current = mtime_read();
    mtimecmp_write(current + 50000);

    asm volatile("csrs mstatus, %0" :: "r"(1 << 3));

    printf("Waiting for mtime interrupt...\n");

    int timeout = 0;
    while (!trap_hit_flag) {
        timeout++;
        if (timeout > 1000000) {
            printf("[FAIL] Timeout waiting for interrupt.\n");
            break;
        }
    }

    asm volatile("csrc mstatus, %0" :: "r"(1 << 3));
    asm volatile("csrc mie, %0" :: "r"(1 << 7));

    if (trap_hit_flag) {
        if (trap_cause_val == 0x80000007) {
            printf("[OK] mtime interrupt correctly triggered and handled.\n");
            printf("--- MTIME TEST PASSED! ---\n");
        } else {
            printf("[FAIL] Interrupt triggered but wrong cause: 0x%x (expected 0x80000007)\n", trap_cause_val);
        }
    }
}

static void shell_test_csr(const char *arg) {
    if (arg && *arg) {
        puts("Usage: test-csr");
        return;
    }

    printf("--- CSR Read/Write Test Start ---\n");
    int test_pass = 1;
    uint32_t read_val;

    uint32_t test_val_1 = 0xDEADBEEF;
    write_mscratch(test_val_1);
    read_val = read_mscratch();
    
    if (read_val == test_val_1) {
        printf("[OK] mscratch RW test passed (0x%x).\n", read_val);
    } else {
        printf("[FAIL] mscratch RW test failed. Expected: 0x%x, Got: 0x%x\n", test_val_1, read_val);
        test_pass = 0;
    }

    uint32_t test_val_2 = 0x80000003;
    asm volatile("csrw mtvec, %0" :: "r"(test_val_2));
    read_val = read_mtvec();
    
    uint32_t expected_mtvec = 0x80000000;
    if (read_val == expected_mtvec) {
        printf("[OK] mtvec alignment test passed (0x%x).\n", read_val);
    } else {
        printf("[FAIL] mtvec alignment test failed. Expected: 0x%x, Got: 0x%x\n", expected_mtvec, read_val);
        test_pass = 0;
    }

    asm volatile("csrw mscratch, %0" :: "r"(0x00000000));
    asm volatile("csrs mscratch, %0" :: "r"(0x00000110));
    read_val = read_mscratch();
    if (read_val == 0x00000110) {
        printf("[OK] mscratch CSRS (Set) test passed.\n");
    } else {
        printf("[FAIL] mscratch CSRS test failed. Got: 0x%x\n", read_val);
        test_pass = 0;
    }

    asm volatile("csrc mscratch, %0" :: "r"(0x00000010));
    read_val = read_mscratch();
    if (read_val == 0x00000100) {
        printf("[OK] mscratch CSRC (Clear) test passed.\n");
    } else {
        printf("[FAIL] mscratch CSRC test failed. Got: 0x%x\n", read_val);
        test_pass = 0;
    }
    if (test_pass) {
        printf("--- ALL TESTS PASSED! ---\n");
    } else {
        printf("--- SOME TESTS FAILED! ---\n");
    }

    puts("");

    printf("--- Trap (ECALL/MRET) Test Start ---\n");
    uint32_t trap_addr = (uint32_t)&trap_handler;
    asm volatile("csrw mtvec, %0" :: "r"(trap_addr));
    
    trap_hit_flag = 0;
    trap_cause_val = 0;
    
    printf("[INFO] mtvec set to 0x%x\n", trap_addr);
    printf("[INFO] Executing ECALL...\n");
    asm volatile("ecall");
    printf("[INFO] Returned from ECALL!\n");
    if (trap_hit_flag == 1 && trap_cause_val == 11) {
        printf("--- ECALL TRAP TEST PASSED! ---\n");
    } else {
        printf("--- ECALL TRAP TEST FAILED! flag=%d, cause=%d ---\n", 
               trap_hit_flag, trap_cause_val);
    }
}

static void shell_test_m(const char *arg) {
    if (arg && *arg) {
        puts("Usage: test-m");
        return;
    }

    puts("=== M Extension Test ===");
    puts("");

    // Test 1: Basic multiplication (MUL)
    puts("Test 1: Basic Multiplication (MUL)");
    int a1 = 12345, b1 = 6789;
    int mul_result = a1 * b1;
    printf("  %d * %d = %d\n", a1, b1, mul_result);
    printf("  Expected: %d\n", 83810205);
    puts("");

    // Test 2: Signed multiplication
    puts("Test 2: Signed Multiplication");
    int a2 = -1234, b2 = 5678;
    int mul_signed = a2 * b2;
    printf("  %d * %d = %d\n", a2, b2, mul_signed);
    printf("  Expected: %d\n", -7006652);
    puts("");

    // Test 3: Basic division (DIV)
    puts("Test 3: Basic Division (DIV)");
    int a3 = 100, b3 = 7;
    int div_result = a3 / b3;
    int rem_result = a3 % b3;
    printf("  %d / %d = %d (remainder %d)\n", a3, b3, div_result, rem_result);
    printf("  Expected: 14 (remainder 2)\n");
    puts("");

    // Test 4: Signed division
    puts("Test 4: Signed Division");
    int a4 = -100, b4 = 7;
    int div_signed = a4 / b4;
    int rem_signed = a4 % b4;
    printf("  %d / %d = %d (remainder %d)\n", a4, b4, div_signed, rem_signed);
    printf("  Expected: -14 (remainder -2)\n");
    puts("");

    // Test 5: Large multiplication (unsigned)
    puts("Test 5: Large Multiplication");
    unsigned int a5 = 65535, b5 = 65535;
    unsigned int mul_large = a5 * b5;
    printf("  %u * %u = %u\n", a5, b5, mul_large);
    printf("  Expected: %u\n", (unsigned)4294836225U);
    puts("");

    // Test 6: Division by zero (according to RISC-V spec)
    puts("Test 6: Division by Zero");
    volatile int a6 = 100;
    volatile int b6 = 0;
    volatile int div_zero = a6 / b6;
    volatile int rem_zero = a6 % b6;
    printf("  %d / %d = %d (remainder %d)\n", (int)a6, (int)b6, (int)div_zero, (int)rem_zero);
    printf("  Expected: -1 (remainder 100) [RISC-V spec]\n");
    puts("");

    // Test 7: Performance test
    puts("Test 7: Performance Test");

    uint64_t cycle_start = rdcycle();

    // Execute 1000 multiplication and division operations
    volatile int sum = 0;
    for (int i = 1; i <= 1000; i++) {
        sum += (i * 123) / 45;
    }

    uint64_t cycle_end = rdcycle();
    uint64_t cycles = cycle_end - cycle_start;

    printf("  1000 operations completed in %llu cycles\n", cycles);
    printf("  Result: %d\n", sum);
    puts("");

    puts("=== Test Complete ===");
}

static void shell_i2c_scan(const char *arg) {
    if (arg && *arg) {
        puts("Usage: i2c_scan");
        return;
    }

    puts("I2C scan (0x03..0x77):");
    int found = 0;
    for (int addr = 0x03; addr <= 0x77; ++addr) {
        if (i2c_probe_7bit((uint8_t)addr)) {
            printf("  found: 0x%x\n", addr);
            found++;
        }
    }
    if (found == 0) {
        puts("  (no devices)");
    } else {
        printf("Done, %d device(s) found.\n", found);
    }
}

static int parse_u32_dec(const char *s, uint32_t *out) {
    if (!s)
        return 0;
    while (*s == ' ')
        ++s;
    if (*s == 0)
        return 0;

    uint32_t value = 0;
    int any = 0;
    while (*s >= '0' && *s <= '9') {
        any = 1;
        uint32_t digit = (uint32_t)(*s - '0');
        if (value > (0xFFFFFFFFu - digit) / 10u)
            return 0;
        value = value * 10u + digit;
        ++s;
    }

    while (*s == ' ')
        ++s;
    if (*s != 0)
        return 0;

    if (!any)
        return 0;
    *out = value;
    return 1;
}

static int parse_u32_dec_prefix(const char **ps, uint32_t *out) {
    const char *s = ps ? *ps : 0;
    if (!s)
        return 0;

    while (*s == ' ')
        ++s;
    if (*s == 0)
        return 0;

    uint32_t value = 0;
    int any = 0;
    while (*s >= '0' && *s <= '9') {
        any = 1;
        uint32_t digit = (uint32_t)(*s - '0');
        if (value > (0xFFFFFFFFu - digit) / 10u)
            return 0;
        value = value * 10u + digit;
        ++s;
    }

    if (!any)
        return 0;
    *out = value;
    *ps = s;
    return 1;
}

static int parse_two_u32_dec(const char *s, uint32_t *a, uint32_t *b) {
    if (!s)
        return 0;
    if (!parse_u32_dec_prefix(&s, a))
        return 0;
    while (*s == ' ')
        ++s;
    if (*s == 0)
        return 0;
    if (!parse_u32_dec_prefix(&s, b))
        return 0;
    while (*s == ' ')
        ++s;
    return *s == 0;
}

static int parse_u32_auto(const char *s, uint32_t *out) {
    if (!s)
        return 0;
    while (*s == ' ')
        ++s;
    if (*s == 0)
        return 0;

    int base = 10;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        base = 16;
        s += 2;
        if (*s == 0)
            return 0;
    }

    uint32_t value = 0;
    int any = 0;
    for (; *s; ++s) {
        int digit = -1;
        char c = *s;
        if (c >= '0' && c <= '9')
            digit = (int)(c - '0');
        else if (base == 16 && c >= 'a' && c <= 'f')
            digit = (int)(c - 'a') + 10;
        else if (base == 16 && c >= 'A' && c <= 'F')
            digit = (int)(c - 'A') + 10;
        else
            return 0;

        any = 1;
        if (value > (0xFFFFFFFFu - (uint32_t)digit) / (uint32_t)base)
            return 0;
        value = value * (uint32_t)base + (uint32_t)digit;
    }

    if (!any)
        return 0;
    *out = value;
    return 1;
}

static char* next_token(char **ps) {
    if (!ps || !*ps)
        return 0;

    char *s = *ps;
    while (*s == ' ')
        ++s;
    if (*s == 0) {
        *ps = s;
        return 0;
    }

    char *tok = s;
    while (*s && *s != ' ')
        ++s;
    if (*s) {
        *s = 0;
        ++s;
    }
    *ps = s;
    return tok;
}

static int wait_ticks_or_keypress(uint32_t ticks) {
    uint32_t start = timer_get_count();
    while ((uint32_t)(timer_get_count() - start) < ticks) {
        if (uart_getc_nonblocking() >= 0)
            return 1;
    }
    return 0;
}

static void shell_blink(const char *arg) {
    uint32_t seconds;
    if (!parse_u32_dec(arg, &seconds) || seconds == 0) {
        puts("Usage: blink <seconds>");
        return;
    }

    uint32_t tps = timer_ticks_per_sec();
    if (tps == 0) {
        puts("Error: timer not initialized");
        return;
    }

    uint32_t ticks;
    if (seconds > (0xFFFFFFFFu / tps)) {
        puts("Error: seconds too large");
        return;
    }
    ticks = seconds * tps;

    puts("Blinking. Press any key to stop.");

    const uint8_t pat0 = 0x15; // 010101
    const uint8_t pat1 = 0x2A; // 101010
    uint8_t pat = pat0;

    while (1) {
        gpio_set_leds(pat);
        pat = (pat == pat0) ? pat1 : pat0;

        if (wait_ticks_or_keypress(ticks))
            break;
    }

    gpio_set_leds(0);
}

static void shell_sdcard_rd(const char *arg) {
    uint32_t skip, count;
    if (!parse_two_u32_dec(arg, &skip, &count)) {
        puts("Usage: sdcard_rd <skip> <count>");
        return;
    }
    if (skip >= 512u || count > 512u || (skip + count) > 512u) {
        puts("Error: range must be within 0..511");
        return;
    }

    static uint8_t sector[512];
    if (sdcard_read_block(0u, sector) != 0) {
        printf("Error: sdcard read failed (err=0x%x)\n", (unsigned int)sdcard_last_error());
        return;
    }

    puts("SD sector0:");
    static const char hex[] = "0123456789ABCDEF";
    for (uint32_t i = 0; i < count; ++i) {
        uint8_t b = sector[skip + i];
        putchar(hex[b >> 4]);
        putchar(hex[b & 0x0F]);
        putchar(' ');
        if ((i & 15u) == 15u)
            putchar('\n');
    }
    if ((count & 15u) != 0u)
        putchar('\n');
}

static void shell_ddr(const char *arg) {
    if (!arg || *arg == 0) {
        puts("Usage:");
        puts("  ddr probe");
        puts("  ddr rd <app_addr> [count]");
        puts("  ddr wr <app_addr> <w0> <w1> <w2> <w3>");
        puts("Notes:");
        puts("  - app_addr is DDR IP app addr (often counted in 2-byte units).");
        puts("  - Each op transfers 128-bit (4x32). count increments app_addr by +8.");
        puts("  - Numbers accept decimal or 0xHEX.");
        return;
    }

    char *p = (char *)arg;
    char *sub = next_token(&p);
    if (!sub) {
        puts("Usage: ddr probe|rd|wr ...");
        return;
    }

    if (str_equals(sub, "probe")) {
        uint32_t st = ddr_get_status();
        printf("DDR STATUS = 0x%x\n", st);
        printf("  present=%d init=%d busy=%d done=%d err=%d cmd_rdy=%d wdata_rdy=%d rd_valid=%d\n",
               (st >> DDR_STATUS_PRESENT_BIT) & 1u,
               (st >> DDR_STATUS_INIT_DONE_BIT) & 1u,
               (st >> DDR_STATUS_BUSY_BIT) & 1u,
               (st >> DDR_STATUS_DONE_BIT) & 1u,
               (st >> DDR_STATUS_ERR_BIT) & 1u,
               (st >> DDR_STATUS_CMD_RDY_BIT) & 1u,
               (st >> DDR_STATUS_WR_DATA_RDY_BIT) & 1u,
               (st >> DDR_STATUS_RD_VALID_BIT) & 1u);
        return;
    }

    if (!ddr_present()) {
        puts("Error: DDR APP MMIO not present (not wired/decoded?)");
        return;
    }
    if (!ddr_init_done()) {
        puts("Error: DDR init_calib_complete is 0 (DDR not ready)");
        return;
    }

    if (str_equals(sub, "rd")) {
        char *tok_addr = next_token(&p);
        uint32_t addr;
        if (!tok_addr || !parse_u32_auto(tok_addr, &addr)) {
            puts("Usage: ddr rd <app_addr> [count]");
            return;
        }
        uint32_t count = 1;
        char *tok_count = next_token(&p);
        if (tok_count && *tok_count) {
            if (!parse_u32_auto(tok_count, &count) || count == 0) {
                puts("Error: invalid count");
                return;
            }
        }

        for (uint32_t i = 0; i < count; ++i) {
            uint32_t out[4];
            int rc = ddr_read128(addr, out);
            if (rc != 0) {
                printf("Error: ddr_read128 failed (rc=%d)\n", rc);
                return;
            }
            printf("DDR[0x%x] = %x %x %x %x\n", addr, out[3], out[2], out[1], out[0]);
            addr += 8u;
        }
        return;
    }

    if (str_equals(sub, "wr")) {
        char *tok_addr = next_token(&p);
        uint32_t addr;
        if (!tok_addr || !parse_u32_auto(tok_addr, &addr)) {
            puts("Usage: ddr wr <app_addr> <w0> <w1> <w2> <w3>");
            return;
        }

        uint32_t w[4];
        for (int i = 0; i < 4; ++i) {
            char *tok = next_token(&p);
            if (!tok || !parse_u32_auto(tok, &w[i])) {
                puts("Usage: ddr wr <app_addr> <w0> <w1> <w2> <w3>");
                return;
            }
        }

        int rc = ddr_write128(addr, w);
        if (rc != 0) {
            printf("Error: ddr_write128 failed (rc=%d)\n", rc);
            return;
        }
        puts("OK");
        return;
    }

    puts("Unknown ddr subcommand. Use: ddr probe|rd|wr");
}

static int str_equals(const char *a, const char *b) {
    while (*a && *b) {
        if (*a != *b)
            return 0;
        ++a;
        ++b;
    }
    return (*a == 0 && *b == 0);
}

static int read_line(char *buf, int maxlen) {
    int idx = 0;
    while (idx < maxlen - 1) {
        int ch = uart_getc_blocking();
        if (ch == '\r')
            ch = '\n';

        if (ch == '\n') {
            putchar('\r');
            putchar('\n');
            break;
        }

        if (ch == 0x7f || ch == '\b') {
            if (idx > 0) {
                idx--;
                putchar('\b');
                putchar(' ');
                putchar('\b');
            }
            continue;
        }

        putchar(ch);
        buf[idx++] = ch;
    }
    buf[idx] = 0;
    return idx;
}

int main() {
    uart_init();
    gpio_init();
    i2c_init(27000000u, 100000u);
    spi_init(27000000u, 200000u);
    timer_init_1mhz(27000000u);

    puts("Simple shell ready. Type 'help' for commands.");

    char line[128];
    while (1) {
        printf("> ");
        int len = read_line(line, sizeof(line));
        if (len <= 0)
            continue;
        char *cmd = line;
        while (*cmd == ' ')
            ++cmd;

        if (*cmd == 0)
            continue;

        char *arg = cmd;
        while (*arg && *arg != ' ')
            ++arg;
        if (*arg) {
            *arg++ = 0;
            while (*arg == ' ')
                ++arg;
        }

        if (str_equals(cmd, "help")) {
            shell_help();
        } else if (str_equals(cmd, "led")) {
            shell_set_leds(arg);
        } else if (str_equals(cmd, "print")) {
            shell_print_text(arg);
        } else if (str_equals(cmd, "i2c_scan")) {
            shell_i2c_scan(arg);
        } else if (str_equals(cmd, "raystones")) {
            shell_run_raystones(arg);
        } else if (str_equals(cmd, "test-m")) {
            shell_test_m(arg);
        } else if (str_equals(cmd, "test-csr")) {
            shell_test_csr(arg);
        } else if (str_equals(cmd, "test-irq")) {
            shell_test_irq(arg);
        } else if (str_equals(cmd, "test-mtime")) {
            shell_test_mtime(arg);
        } else if (str_equals(cmd, "blink")) {
            shell_blink(arg);
        } else if (str_equals(cmd, "sdcard_rd")) {
            shell_sdcard_rd(arg);
        } else if (str_equals(cmd, "ddr")) {
            shell_ddr(arg);
        } else {
            puts("Unknown command. Type 'help'.");
        }
    }

    return 0;
}
