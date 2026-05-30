#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
#include "timers.h"
#include "test_rtos.h"
#include "uart.h"
#include "print.h"

extern int puts(const char *s);

static void rtos_puts(const char *s)
{
    uint32_t mstatus;
    uint32_t mie_mask = 8u;

    asm volatile("csrrc %0, mstatus, %1" : "=r"(mstatus) : "r"(mie_mask) : "memory");

    while (*s != '\0')
        uart_putc_blocking((uint8_t)*s++);
    uart_putc_blocking((uint8_t)'\n');

    if ((mstatus & mie_mask) != 0)
        asm volatile("csrs mstatus, %0" :: "r"(mie_mask) : "memory");
}

static void task_a(void *param)
{
    (void)param;

    for (;;) {
        rtos_puts("[TaskA] ping");
        vTaskDelay(pdMS_TO_TICKS(200));
    }
}

static void task_b(void *param)
{
    (void)param;

    for (;;) {
        rtos_puts("[TaskB] pong");
        vTaskDelay(pdMS_TO_TICKS(300));
    }
}

static void task_self_delete(void *param)
{
    (void)param;
    rtos_puts("[TaskC] Hello - I will delete myself now.");
    vTaskDelete(NULL);
}

static void timer_oneshot_cb(TimerHandle_t xTimer)
{
    (void)xTimer;
    rtos_puts("[Timer] one-shot fired (300 ms)");
}

static unsigned periodic_count = 0;

static void timer_periodic_cb(TimerHandle_t xTimer)
{
    (void)xTimer;
    periodic_count++;

    if (periodic_count == 1)
        rtos_puts("[Timer] periodic tick 1 (350 ms)");
    else if (periodic_count == 2)
        rtos_puts("[Timer] periodic tick 2 (350 ms)");
    else if (periodic_count == 3)
        rtos_puts("[Timer] periodic tick 3 (350 ms)");

    if (periodic_count >= 3) {
        rtos_puts("[Timer] periodic stopping after 3 ticks.");
        xTimerStop(xTimer, 0);
    }
}

void shell_test_rtos(const char *arg)
{
    TimerHandle_t t1;
    TimerHandle_t t2;
    BaseType_t rc;
    extern void freertos_risc_v_trap_handler(void);
    uint32_t trap_addr = (uint32_t)freertos_risc_v_trap_handler;

    (void)arg;

    asm volatile("csrw mtvec, %0" :: "r"(trap_addr));

    puts("--- FreeRTOS Test ---");

    /* Force heap init, then check */
    printf("sizeof(StackType_t)=%u\n",
           (unsigned)sizeof(StackType_t));
    printf("Before any alloc: free=%u minFree=%u\n",
           (unsigned)xPortGetFreeHeapSize(),
           (unsigned)xPortGetMinimumEverFreeHeapSize());

    /* Alloc 4 bytes to force prvHeapInit, then check free */
    void *p = pvPortMalloc(4);
    printf("After prvHeapInit: free=%u minFree=%u p=0x%x\n",
           (unsigned)xPortGetFreeHeapSize(),
           (unsigned)xPortGetMinimumEverFreeHeapSize(),
           (unsigned)p);
    vPortFree(p);
    printf("After vPortFree(p): free=%u\n",
           (unsigned)xPortGetFreeHeapSize());

    rc = xTaskCreate(task_a, "A", 1024, NULL, 2, NULL);
    printf("After TaskA: free=%u minFree=%u\n",
           (unsigned)xPortGetFreeHeapSize(),
           (unsigned)xPortGetMinimumEverFreeHeapSize());
    if (rc != pdPASS)
        printf("[FAIL] xTaskCreate(TaskA) failed\n");

    rc = xTaskCreate(task_b, "B", 1024, NULL, 2, NULL);
    printf("After TaskB: free=%u minFree=%u\n",
           (unsigned)xPortGetFreeHeapSize(),
           (unsigned)xPortGetMinimumEverFreeHeapSize());
    if (rc != pdPASS)
        printf("[FAIL] xTaskCreate(TaskB) failed\n");

    rc = xTaskCreate(task_self_delete, "C", 1024, NULL, 2, NULL);
    printf("After TaskC: free=%u minFree=%u rc=%d\n",
           (unsigned)xPortGetFreeHeapSize(),
           (unsigned)xPortGetMinimumEverFreeHeapSize(),
           (int)rc);
    if (rc != pdPASS)
        printf("[FAIL] xTaskCreate(TaskC) failed\n");

    t1 = xTimerCreate("oneshot", pdMS_TO_TICKS(300), pdFALSE, (void *)0, timer_oneshot_cb);
    if (t1 != NULL) {
        if (xTimerStart(t1, 0) != pdPASS)
            puts("[WARN] xTimerStart(oneshot) failed");
    } else {
        puts("[WARN] xTimerCreate(oneshot) failed");
    }

    t2 = xTimerCreate("periodic", pdMS_TO_TICKS(350), pdTRUE, (void *)0, timer_periodic_cb);
    if (t2 != NULL) {
        if (xTimerStart(t2, 0) != pdPASS)
            puts("[WARN] xTimerStart(periodic) failed");
    } else {
        puts("[WARN] xTimerCreate(periodic) failed");
    }

    puts("[OK] Created one-shot timer (300 ms) and periodic timer (350 ms x3)");
    puts("Scheduler running (sim exits at max-cycles)...");

    vTaskStartScheduler();

    puts("[FAIL] Scheduler returned!");

    while (1);
    
}
