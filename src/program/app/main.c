#include "autoconf.h"
#include <stdint.h>
#include "uart.h"
#include "gpio.h"
#include "i2c.h"
#include "spi.h"
#include "sdcard.h"
#include "timer.h"
#include "clint.h"
#include "lcd.h"
#include "print.h"
#include "fatboot.h"
#include "boot_image.h"
#include "xmodem.h"
#include "test_priv.h"
#include "test_sv32.h"

#if defined(CONFIG_APP_TEST_CSR) || defined(CONFIG_APP_TEST_IRQ) || defined(CONFIG_APP_TEST_MTIME)
#include "test_csr.h"
#endif

#ifdef CONFIG_APP_TEST_MSIP
#include "test_msip.h"
#endif

#ifdef CONFIG_APP_TEST_SHIFT
#include "test_shift.h"
#endif

#ifdef CONFIG_APP_TEST_A
#include "test_a.h"
#endif

void raystones_run(void);

typedef void (*entry_fn)(uint32_t hartid, uintptr_t fdt_addr);

static void boot_jump_to_ddr(void) {
    asm volatile("csrwi mstatus, 0\ncsrwi mie, 0" ::: "memory");
    ((entry_fn)BOOT_IMAGE_LOAD_ADDR)(0, 0);

    for (;;) {
    }
}

#ifdef CONFIG_APP_TEST_M
static inline uint64_t rdcycle(void) {
    uint32_t lo, hi, hi_check;
    do {
        asm volatile("rdcycleh %0" : "=r"(hi));
        asm volatile("rdcycle %0" : "=r"(lo));
        asm volatile("rdcycleh %0" : "=r"(hi_check));
    } while (hi != hi_check);
    return ((uint64_t)hi << 32) | lo;
}
#endif

static int str_equals(const char *a, const char *b) {
    while (*a && *b) {
        if (*a != *b) return 0;
        ++a; ++b;
    }
    return (*a == 0 && *b == 0);
}

static int parse_u32_dec(const char *s, uint32_t *out) {
    if (!s) return 0;
    while (*s == ' ') ++s;
    if (*s == 0) return 0;
    uint32_t value = 0;
    int any = 0;
    while (*s >= '0' && *s <= '9') {
        any = 1;
        uint32_t digit = (uint32_t)(*s - '0');
        if (value > (0xFFFFFFFFu - digit) / 10u) return 0;
        value = value * 10u + digit;
        ++s;
    }
    while (*s == ' ') ++s;
    if (*s != 0) return 0;
    if (!any) return 0;
    *out = value;
    return 1;
}

static int parse_u32_dec_prefix(const char **ps, uint32_t *out) {
    const char *s = ps ? *ps : 0;
    if (!s) return 0;
    while (*s == ' ') ++s;
    if (*s == 0) return 0;
    uint32_t value = 0;
    int any = 0;
    while (*s >= '0' && *s <= '9') {
        any = 1;
        uint32_t digit = (uint32_t)(*s - '0');
        if (value > (0xFFFFFFFFu - digit) / 10u) return 0;
        value = value * 10u + digit;
        ++s;
    }
    if (!any) return 0;
    *out = value;
    *ps = s;
    return 1;
}

static int parse_three_u32_dec(const char *s, uint32_t *a, uint32_t *b, uint32_t *c) {
    if (!s) return 0;
    if (!parse_u32_dec_prefix(&s, a)) return 0;
    while (*s == ' ') ++s;
    if (*s == 0 || !parse_u32_dec_prefix(&s, b)) return 0;
    while (*s == ' ') ++s;
    if (*s == 0 || !parse_u32_dec_prefix(&s, c)) return 0;
    while (*s == ' ') ++s;
    return *s == 0;
}

static int wait_ticks_or_keypress(uint32_t ticks) {
    uint32_t start = timer_get_count();
    while ((uint32_t)(timer_get_count() - start) < ticks) {
        if (uart_getc_nonblocking() >= 0) return 1;
    }
    return 0;
}

static int read_line(char *buf, int maxlen) {
    int idx = 0;
    while (idx < maxlen - 1) {
        int ch = uart_getc_blocking();
        if (ch == '\r') ch = '\n';
        if (ch == '\n') { putchar('\r'); putchar('\n'); break; }
        if (ch == 0x7f || ch == '\b') {
            if (idx > 0) { idx--; putchar('\b'); putchar(' '); putchar('\b'); }
            continue;
        }
        putchar(ch);
        buf[idx++] = ch;
    }
    buf[idx] = 0;
    return idx;
}

static void shell_help(void) {
    puts("Commands:");
    puts("  help               - show this help");
    puts("  led <6-bit-bin>    - set LEDs, e.g. led 101010");
    puts("  blink <seconds>    - alternate LEDs every N seconds");
    puts("  print <text>       - print text");
    puts("  i2c_scan           - scan I2C 7-bit addresses");
    puts("  sdcard_rd <lba> <skip> <count> - read SD sector and hex dump bytes");
    puts("  raystones          - run the raystones benchmark");
    puts("  sdload             - load BOOT.BIN from SD and jump to DDR app");
    puts("  uartload           - receive BOOT.BIN via XMODEM-CRC and jump to DDR app");
    puts("  ddrboot            - jump to a preloaded image at 0x80000000");
    puts("  lcd                - draw colorbar on the DDR-backed LCD framebuffer");
    puts("  test-priv          - test Bare M/S/U privilege transitions");
    puts("  test-sv32          - test Sv32 data translation and page walk");
#ifdef CONFIG_APP_TEST_M
    puts("  test-m             - test M extension (multiply/divide)");
#endif
#ifdef CONFIG_APP_TEST_CSR
    puts("  test-csr           - test CSRs and trap handling");
#endif
#ifdef CONFIG_APP_TEST_IRQ
    puts("  test-irq           - test asynchronous hardware interrupts");
#endif
#ifdef CONFIG_APP_TEST_MTIME
    puts("  test-mtime         - read and display machine timer");
#endif
#ifdef CONFIG_APP_TEST_MSIP
    puts("  test-msip          - test machine software interrupt (MSIP)");
#endif
#ifdef CONFIG_APP_TEST_SHIFT
    puts("  test-shift         - test SRA/SRAI and uint16 CRC");
#endif
#ifdef CONFIG_APP_TEST_A
    puts("  test-a             - test RV32A LR/SC and AMO instructions");
#endif
}

static void shell_set_leds(const char *arg) {
    if (arg == 0 || *arg == 0) { puts("Usage: led <6-bit-binary>"); return; }
    uint8_t value = 0;
    int count = 0;
    while (arg[count] == '0' || arg[count] == '1') {
        value = (value << 1) | (arg[count] - '0');
        count++;
        if (count > 6) break;
    }
    if (count != 6 || (arg[count] != 0 && arg[count] != ' ')) {
        puts("Error: provide exactly 6 binary digits, e.g. led 101010");
        return;
    }
    gpio_set_leds(value);
    uint8_t actual = gpio_get_leds();
    printf("LEDs set to 0b");
    for (int bit = 5; bit >= 0; --bit) putchar(((value >> bit) & 1) ? '1' : '0');
    printf(" (readback 0b");
    for (int bit = 5; bit >= 0; --bit) putchar(((actual >> bit) & 1) ? '1' : '0');
    puts(")");
}

static void shell_print_text(const char *arg) {
    if (!arg || *arg == 0) { puts("Usage: print <text>"); return; }
    puts(arg);
}

static void shell_run_raystones(const char *arg) {
    if (arg && *arg) { puts("Usage: raystones"); return; }
    raystones_run();
}

static void shell_i2c_scan(const char *arg) {
    if (arg && *arg) { puts("Usage: i2c_scan"); return; }
    puts("I2C scan (0x03..0x77):");
    int found = 0;
    for (int addr = 0x03; addr <= 0x77; ++addr) {
        if (i2c_probe_7bit((uint8_t)addr)) {
            printf("  found: 0x%x\n", addr);
            found++;
        }
    }
    if (found == 0) puts("  (no devices)");
    else printf("Done, %d device(s) found.\n", found);
}

static void shell_blink(const char *arg) {
    uint32_t seconds;
    if (!parse_u32_dec(arg, &seconds) || seconds == 0) {
        puts("Usage: blink <seconds>");
        return;
    }
    uint32_t tps = timer_ticks_per_sec();
    if (tps == 0) { puts("Error: timer not initialized"); return; }
    if (seconds > (0xFFFFFFFFu / tps)) { puts("Error: seconds too large"); return; }
    uint32_t ticks = seconds * tps;
    puts("Blinking. Press any key to stop.");
    const uint8_t pat0 = 0x15;
    const uint8_t pat1 = 0x2A;
    uint8_t pat = pat0;
    while (1) {
        gpio_set_leds(pat);
        pat = (pat == pat0) ? pat1 : pat0;
        if (wait_ticks_or_keypress(ticks)) break;
    }
    gpio_set_leds(0);
}

static void shell_sdcard_rd(const char *arg) {
    uint32_t lba, skip, count;
    if (!parse_three_u32_dec(arg, &lba, &skip, &count)) {
        puts("Usage: sdcard_rd <lba> <skip> <count>");
        return;
    }
    if (skip >= 512u || count > 512u || (skip + count) > 512u) {
        puts("Error: range must be within 0..511");
        return;
    }
    static uint8_t sector[512];
    if (sdcard_read_block(lba, sector) != 0) {
        printf("Error: sdcard read failed (err=0x%x)\n", (unsigned int)sdcard_last_error());
        return;
    }
    printf("SD sector %u:\n", (unsigned int)lba);
    static const char hex[] = "0123456789ABCDEF";
    for (uint32_t i = 0; i < count; ++i) {
        uint8_t b = sector[skip + i];
        putchar(hex[b >> 4]);
        putchar(hex[b & 0x0F]);
        putchar(' ');
        if ((i & 15u) == 15u) putchar('\n');
    }
    if ((count & 15u) != 0u) putchar('\n');
}

static void shell_lcd(const char *arg) {
    if (arg && *arg) { puts("Usage: lcd"); return; }
    lcd_colorbar();
    puts("LCD colorbar written to DDR framebuffer.");
}

static void shell_sdload(const char *arg) {
    if (arg && *arg) {
        puts("Usage: sdload");
        return;
    }

    puts("Bootloader: SD FAT32 DDR boot");

    if (sdcard_init() != 0) {
        printf("Bootloader: SD init failed err=0x%x\n", (unsigned int)sdcard_last_error());
        return;
    }
    puts("Bootloader: SD ready");
    printf("Bootloader: SD addressing %s ocr=0x%x\n",
           sdcard_is_high_capacity() ? "SDHC block" : "SDSC byte",
           (unsigned int)sdcard_ocr());

    uint32_t size = 0;
    int rc = fatboot_load(0x80000000u, &size);
    if (rc != 0) {
        uint32_t crc = sdcard_last_crc();
        printf("Bootloader: FAT load failed rc=%d err=0x%x st=0x%x dbg=0x%x crc_rx=0x%x crc_calc=0x%x\n",
               rc, (unsigned int)sdcard_last_error(),
               (unsigned int)sdcard_last_status(),
               (unsigned int)sdcard_last_debug(),
               (unsigned int)(crc >> 16), (unsigned int)(crc & 0xffffu));
        return;
    }

    printf("Bootloader: SD image ready (%u bytes)\n", (unsigned)size);
    boot_jump_to_ddr();
}

static void shell_uartload(const char *arg) {
    if (arg && *arg) {
        puts("Usage: uartload");
        return;
    }

    puts("Bootloader: UART XMODEM DDR boot");
    puts("Send BOOT.BIN using xmodem crc now.");

    uint32_t size = 0;
    int rc = xmodem_load_boot_image(BOOT_IMAGE_LOAD_ADDR, &size);
    if (rc != 0) {
        printf("Bootloader: UART load failed rc=%d\n", rc);
        return;
    }

    printf("Bootloader: UART image ready (%u bytes)\n", (unsigned)size);
    boot_jump_to_ddr();
}

static void shell_ddrboot(const char *arg) {
    if (arg && *arg) { puts("Usage: ddrboot"); return; }
    boot_jump_to_ddr();
}

#ifdef CONFIG_APP_TEST_M
static void shell_test_m(const char *arg) {
    if (arg && *arg) { puts("Usage: test-m"); return; }

    puts("=== M Extension Test ===");
    puts("");

    puts("Test 1: Basic Multiplication (MUL)");
    int a1 = 12345, b1 = 6789;
    int mul_result = a1 * b1;
    printf("  %d * %d = %d\n", a1, b1, mul_result);
    printf("  Expected: %d\n", 83810205);
    puts("");

    puts("Test 2: Signed Multiplication");
    int a2 = -1234, b2 = 5678;
    int mul_signed = a2 * b2;
    printf("  %d * %d = %d\n", a2, b2, mul_signed);
    printf("  Expected: %d\n", -7006652);
    puts("");

    puts("Test 3: Basic Division (DIV)");
    int a3 = 100, b3 = 7;
    int div_result = a3 / b3;
    int rem_result = a3 % b3;
    printf("  %d / %d = %d (remainder %d)\n", a3, b3, div_result, rem_result);
    printf("  Expected: 14 (remainder 2)\n");
    puts("");

    puts("Test 4: Signed Division");
    int a4 = -100, b4 = 7;
    int div_signed = a4 / b4;
    int rem_signed = a4 % b4;
    printf("  %d / %d = %d (remainder %d)\n", a4, b4, div_signed, rem_signed);
    printf("  Expected: -14 (remainder -2)\n");
    puts("");

    puts("Test 5: Large Multiplication");
    unsigned int a5 = 65535, b5 = 65535;
    unsigned int mul_large = a5 * b5;
    printf("  %u * %u = %u\n", a5, b5, mul_large);
    printf("  Expected: %u\n", (unsigned)4294836225U);
    puts("");

    puts("Test 6: Division by Zero");
    volatile int a6 = 100;
    volatile int b6 = 0;
    volatile int div_zero = a6 / b6;
    volatile int rem_zero = a6 % b6;
    printf("  %d / %d = %d (remainder %d)\n", (int)a6, (int)b6, (int)div_zero, (int)rem_zero);
    printf("  Expected: -1 (remainder 100) [RISC-V spec]\n");
    puts("");

    puts("Test 7: Performance Test");
    uint64_t cycle_start = rdcycle();
    volatile int sum = 0;
    for (int i = 1; i <= 1000; i++) sum += (i * 123) / 45;
    uint64_t cycle_end = rdcycle();
    uint64_t cycles = cycle_end - cycle_start;
    printf("  1000 operations completed in %llu cycles\n", cycles);
    printf("  Result: %d\n", sum);
    puts("");

    puts("=== Test Complete ===");
}
#endif

#ifdef CONFIG_APP_TEST_CSR
static void shell_test_csr(const char *arg) {
    if (arg && *arg) { puts("Usage: test-csr"); return; }

    printf("--- CSR Read/Write Test Start ---\n");
    int test_pass = 1;
    uint32_t read_val;

    uint32_t test_val_1 = 0xDEADBEEF;
    write_mscratch(test_val_1);
    read_val = read_mscratch();
    if (read_val == test_val_1) printf("[OK] mscratch RW test passed (0x%x).\n", read_val);
    else { printf("[FAIL] mscratch RW test failed. Expected: 0x%x, Got: 0x%x\n", test_val_1, read_val); test_pass = 0; }

    uint32_t test_val_2 = 0x80000003;
    asm volatile("csrw mtvec, %0" :: "r"(test_val_2));
    read_val = read_mtvec();
    uint32_t expected_mtvec = 0x80000000;
    if (read_val == expected_mtvec) printf("[OK] mtvec alignment test passed (0x%x).\n", read_val);
    else { printf("[FAIL] mtvec alignment test failed. Expected: 0x%x, Got: 0x%x\n", expected_mtvec, read_val); test_pass = 0; }

    asm volatile("csrw mscratch, %0" :: "r"(0x00000000));
    asm volatile("csrs mscratch, %0" :: "r"(0x00000110));
    read_val = read_mscratch();
    if (read_val == 0x00000110) printf("[OK] mscratch CSRS (Set) test passed.\n");
    else { printf("[FAIL] mscratch CSRS test failed. Got: 0x%x\n", read_val); test_pass = 0; }

    asm volatile("csrc mscratch, %0" :: "r"(0x00000010));
    read_val = read_mscratch();
    if (read_val == 0x00000100) printf("[OK] mscratch CSRC (Clear) test passed.\n");
    else { printf("[FAIL] mscratch CSRC test failed. Got: 0x%x\n", read_val); test_pass = 0; }

    if (test_pass) printf("--- ALL TESTS PASSED! ---\n");
    else           printf("--- SOME TESTS FAILED! ---\n");
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
    if (trap_hit_flag == 1 && trap_cause_val == 11)
        printf("--- ECALL TRAP TEST PASSED! ---\n");
    else
        printf("--- ECALL TRAP TEST FAILED! flag=%d, cause=%d ---\n", trap_hit_flag, trap_cause_val);
}
#endif

static void shell_test_priv(const char *arg) {
    if (arg && *arg) { puts("Usage: test-priv"); return; }

    puts("--- M/S/U Privilege Test Start ---");
    int result = test_privilege_modes();
    if (result == 0)
        puts("--- PRIVILEGE TEST PASSED! ---");
    else
        printf("--- PRIVILEGE TEST FAILED! code=%d ---\n", result);
}

static void shell_test_sv32(const char *arg) {
    if (arg && *arg) { puts("Usage: test-sv32"); return; }

    puts("--- Sv32 Data Translation Test Start ---");
    int result = test_sv32_data();
    if (result != 0) {
        printf("--- SV32 DATA TEST FAILED! code=%d ---\n", result);
        return;
    }
    puts("[OK] Sv32 data mapping");

    result = sv32_fault_test();
    if (result != 0) {
        printf("--- SV32 FAULT TEST FAILED! code=%d ---\n", result);
        return;
    }
    puts("[OK] Sv32 load page fault");

    puts("[INFO] Entering Sv32 supervisor instruction test");
    result = sv32_instruction_test();
    if (result != 0) {
        printf("--- SV32 INSTRUCTION TEST FAILED! code=%d ---\n", result);
        return;
    }

    result = sv32_instruction_fault_test();
    if (result == 0)
        puts("--- SV32 DATA TEST PASSED! ---");
    else
        printf("--- SV32 INSTRUCTION FAULT TEST FAILED! code=%d ---\n", result);
}

#ifdef CONFIG_APP_TEST_IRQ
static void shell_test_irq(const char *arg) {
    if (arg && *arg) { puts("Usage: test-irq"); return; }

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
        if (timeout > 1000000) { printf("[FAIL] Timeout waiting for interrupt.\n"); break; }
    }
    asm volatile("csrc mstatus, %0" :: "r"(1 << 3));
    asm volatile("csrc mie, %0" :: "r"(1 << 11));
    if (trap_hit_flag) {
        if (trap_cause_val == 0x8000000B)
            printf("[OK] Timer peripheral interrupt correctly triggered and handled.\n--- TIMER PERIPHERAL TEST PASSED! ---\n");
        else
            printf("[FAIL] Interrupt triggered but wrong cause: 0x%x (expected 0x8000000B)\n", trap_cause_val);
    }
}
#endif

#ifdef CONFIG_APP_TEST_MTIME
static void shell_test_mtime(const char *arg) {
    if (arg && *arg) { puts("Usage: test-mtime"); return; }

    printf("--- Machine Timer (mtime) Interrupt Test Start ---\n");
    uint32_t trap_addr = (uint32_t)&trap_handler;
    asm volatile("csrw mtvec, %0" :: "r"(trap_addr));
    trap_hit_flag = 0;
    trap_cause_val = 0;
    asm volatile("csrs mie, %0" :: "r"(1 << 7));
    uint64_t current = clint_get_mtime();
    clint_set_mtimecmp(current + 50000);
    asm volatile("csrs mstatus, %0" :: "r"(1 << 3));
    printf("Waiting for mtime interrupt...\n");
    int timeout = 0;
    while (!trap_hit_flag) {
        timeout++;
        if (timeout > 1000000) { printf("[FAIL] Timeout waiting for interrupt.\n"); break; }
    }
    asm volatile("csrc mstatus, %0" :: "r"(1 << 3));
    asm volatile("csrc mie, %0" :: "r"(1 << 7));
    if (trap_hit_flag) {
        if (trap_cause_val == 0x80000007)
            printf("[OK] mtime interrupt correctly triggered and handled.\n--- MTIME TEST PASSED! ---\n");
        else
            printf("[FAIL] Interrupt triggered but wrong cause: 0x%x (expected 0x80000007)\n", trap_cause_val);
    }
}
#endif

int main(void) {
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
        if (len <= 0) continue;
        char *cmd = line;
        while (*cmd == ' ') ++cmd;
        if (*cmd == 0) continue;

        char *arg = cmd;
        while (*arg && *arg != ' ') ++arg;
        if (*arg) { *arg++ = 0; while (*arg == ' ') ++arg; }

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
        } else if (str_equals(cmd, "blink")) {
            shell_blink(arg);
        } else if (str_equals(cmd, "sdcard_rd")) {
            shell_sdcard_rd(arg);
        } else if (str_equals(cmd, "sdload")) {
            shell_sdload(arg);
        } else if (str_equals(cmd, "uartload")) {
            shell_uartload(arg);
        } else if (str_equals(cmd, "ddrboot")) {
            shell_ddrboot(arg);
        } else if (str_equals(cmd, "lcd")) {
            shell_lcd(arg);
        } else if (str_equals(cmd, "test-priv")) {
            shell_test_priv(arg);
        } else if (str_equals(cmd, "test-sv32")) {
            shell_test_sv32(arg);
#ifdef CONFIG_APP_TEST_M
        } else if (str_equals(cmd, "test-m")) {
            shell_test_m(arg);
#endif
#ifdef CONFIG_APP_TEST_CSR
        } else if (str_equals(cmd, "test-csr")) {
            shell_test_csr(arg);
#endif
#ifdef CONFIG_APP_TEST_IRQ
        } else if (str_equals(cmd, "test-irq")) {
            shell_test_irq(arg);
#endif
#ifdef CONFIG_APP_TEST_MTIME
        } else if (str_equals(cmd, "test-mtime")) {
            shell_test_mtime(arg);
#endif
#ifdef CONFIG_APP_TEST_MSIP
        } else if (str_equals(cmd, "test-msip")) {
            shell_test_msip(arg);
#endif
#ifdef CONFIG_APP_TEST_SHIFT
        } else if (str_equals(cmd, "test-shift")) {
            shell_test_shift(arg);
#endif
#ifdef CONFIG_APP_TEST_A
        } else if (str_equals(cmd, "test-a")) {
            shell_test_a(arg);
#endif
        } else {
            puts("Unknown command. Type 'help'.");
        }
    }

    return 0;
}
