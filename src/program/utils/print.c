#include <stdarg.h>
#include <stdint.h>
#include "uart.h"

void print_hex_digits(unsigned int val, int nbdigits);

void print_string(const char *s) {
    for (const char *p = s; *p; ++p)
        putchar(*p);
}

int puts(const char *s) {
    print_string(s);
    putchar('\n');
    return 1;
}

void print_dec(int val) {
    char buffer[12];
    char *p = buffer;
    if (val < 0) {
        putchar('-');
        print_dec(-val);
        return;
    }
    while (val || p == buffer) {
        *(p++) = val % 10;
        val = val / 10;
    }
    while (p != buffer)
        putchar('0' + *(--p));
}

void print_hex(unsigned int val) {
    print_hex_digits(val, 8);
}

void print_hex_digits(unsigned int val, int nbdigits) {
    for (int i = (4 * nbdigits) - 4; i >= 0; i -= 4)
        putchar("0123456789ABCDEF"[(val >> i) % 16]);
}

int printf(const char *fmt, ...) {
    va_list ap;
    for (va_start(ap, fmt); *fmt; fmt++) {
        if (*fmt == '%') {
            fmt++;
            if      (*fmt == 's') print_string(va_arg(ap, char *));
            else if (*fmt == 'x') print_hex(va_arg(ap, int));
            else if (*fmt == 'd') print_dec(va_arg(ap, int));
            else if (*fmt == 'u') {
                unsigned int uval = va_arg(ap, unsigned int);
                if (uval == 0) {
                    putchar('0');
                } else {
                    char buf[12];
                    int i = 0;
                    while (uval > 0) { buf[i++] = (uval % 10) + '0'; uval /= 10; }
                    while (i > 0) putchar(buf[--i]);
                }
            } else if (*fmt == 'l' && *(fmt+1) == 'l' && *(fmt+2) == 'u') {
                fmt += 2;
                unsigned long long v = va_arg(ap, unsigned long long);
                if (v == 0) {
                    putchar('0');
                } else {
                    char buf[24];
                    int i = 0;
                    while (v > 0) { buf[i++] = (v % 10) + '0'; v /= 10; }
                    while (i > 0) putchar(buf[--i]);
                }
            } else if (*fmt == 'c') {
                putchar(va_arg(ap, int));
            } else {
                putchar(*fmt);
            }
        } else {
            putchar(*fmt);
        }
    }
    va_end(ap);
    return 0;
}
