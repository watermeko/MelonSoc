#include <stdarg.h>

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

// 如果 putchar 是在汇编中实现的，并且在此裸机上下文中不是由标准头文件提供的，则声明它
extern int putchar(int c);

int main() {
    // 调用您的打印函数进行测试
    printf("Hello from C! Value: %d, Hex: %x\n", 123, 0xABC);
    puts("This is a test string.");
    // 程序将在此处返回到 program.s 中的 _halt 标签
    return 0;
}
