#ifndef PRINT_H
#define PRINT_H

void print_string(const char *s);
int  puts(const char *s);
void print_dec(int val);
void print_hex(unsigned int val);
void print_hex_digits(unsigned int val, int nbdigits);
int  printf(const char *fmt, ...);

#endif
