#include "uart.h"
#include "print.h"
#include "test_rtos.h"

int main(void)
{
    uart_init();
    puts("DDR app: BOOT.BIN is running from DDR");
    shell_test_rtos(0);

    for (;;) {
    }
}
