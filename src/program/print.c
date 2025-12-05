#include <stdarg.h>
#include "uart.h"

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

int main() {
    uart_init();

    // 调用您的打印函数进行测试
    printf("Hello from C! Value: %d, Hex: %x\n", 123, 0xABC);
    printf("Test mult:%d * %d = %d\n", 7, 6, 7*6);
    printf("Test div:%d / %d = %d\n", 20, 3, 20/3);
    puts("This is a test string.\n");

    printf("UART RX demo: waiting for a character...\n");
    int rx_char = uart_getc_blocking();
    printf("UART RX demo captured: %c (0x%x)\n", rx_char, rx_char);
    printf("Echoing back everything you type.\n");

    while (1) {
        int ch = uart_getc_blocking();
        if (ch == '\r')
            putchar('\n');
        putchar(ch);
    }

    // 程序将在此处返回到 program.s 中的 _halt 标签
    return 0;
}
