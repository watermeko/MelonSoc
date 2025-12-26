#include <stdarg.h>
#include <stdint.h>
#include "uart.h"
#include "gpio.h"
#include "i2c.h"
#include "timer.h"

void raystones_run(void);

void print_hex_digits(unsigned int val, int nbdigits);

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
    puts("  raystones          - run the raystones benchmark");
    puts("  test-m             - test M extension (multiply/divide)");
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

    // Test 5: Large multiplication
    puts("Test 5: Large Multiplication");
    int a5 = 65535, b5 = 65535;
    int mul_large = a5 * b5;
    printf("  %d * %d = %d\n", a5, b5, mul_large);
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
        } else if (str_equals(cmd, "blink")) {
            shell_blink(arg);
        } else {
            puts("Unknown command. Type 'help'.");
        }
    }

    return 0;
}
