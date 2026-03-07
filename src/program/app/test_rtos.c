#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
#include "test_rtos.h"

extern int printf(const char *fmt, ...);
extern int puts(const char *s);

static void task_a(void *param)
{
    (void)param;
    for (;;) {
        puts("[TaskA] ping");
        vTaskDelay(pdMS_TO_TICKS(200));
    }
}

static void task_b(void *param)
{
    (void)param;
    for (;;) {
        puts("[TaskB] pong");
        vTaskDelay(pdMS_TO_TICKS(300));
    }
}

void shell_test_rtos(const char *arg)
{
    (void)arg;

    extern void freertos_risc_v_trap_handler(void);
    uint32_t trap_addr = (uint32_t)freertos_risc_v_trap_handler;
    asm volatile("csrw mtvec, %0" :: "r"(trap_addr));

    puts("--- FreeRTOS Dual-Task Test ---");
    puts("TaskA prints every 200ms, TaskB every 300ms.");
    puts("Scheduler running (sim exits at max-cycles)...");

    xTaskCreate(task_a, "A", configMINIMAL_STACK_SIZE, NULL, 2, NULL);
    xTaskCreate(task_b, "B", configMINIMAL_STACK_SIZE, NULL, 2, NULL);

    vTaskStartScheduler();

    puts("[FAIL] Scheduler returned!");
}
