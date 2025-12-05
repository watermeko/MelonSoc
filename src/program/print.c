#include <stdarg.h>
#include "uart.h"
#include "gpio.h"

void print_hex_digits(unsigned int val, int nbdigits);

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
    puts("  print <text>       - print text");
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
        } else {
            puts("Unknown command. Type 'help'.");
        }
    }

    return 0;
}
