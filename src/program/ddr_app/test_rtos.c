#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
#include "timers.h"
#include "test_rtos.h"
#include "print.h"
#include "queue.h"

static QueueHandle_t g_print_queue;

static BaseType_t queue_print(const char *message, TickType_t ticks_to_wait)
{
    return xQueueSendToBack(g_print_queue, &message, ticks_to_wait);
}

static void printer_task(void *param)
{
    const char *message;

    (void)param;

    for (;;) {
        if (xQueueReceive(g_print_queue, &message, portMAX_DELAY) == pdPASS)
            puts(message);
    }
}

static void task_a(void *param)
{
    (void)param;

    for (;;) {
        queue_print("[TaskA] ping", portMAX_DELAY);
        vTaskDelay(pdMS_TO_TICKS(200));
    }
}

static void task_b(void *param)
{
    (void)param;

    for (;;) {
        queue_print("[TaskB] pong", portMAX_DELAY);
        vTaskDelay(pdMS_TO_TICKS(300));
    }
}

static void task_self_delete(void *param)
{
    (void)param;
    queue_print("[TaskC] Hello - I will delete myself now.", portMAX_DELAY);
    vTaskDelete(NULL);
}

static void timer_oneshot_cb(TimerHandle_t xTimer)
{
    (void)xTimer;
    queue_print("[Timer] one-shot fired (300 ms)", 0);
}

static unsigned periodic_count = 0;

static void timer_periodic_cb(TimerHandle_t xTimer)
{
    (void)xTimer;
    periodic_count++;

    if (periodic_count == 1)
        queue_print("[Timer] periodic tick 1 (350 ms)", 0);
    else if (periodic_count == 2)
        queue_print("[Timer] periodic tick 2 (350 ms)", 0);
    else if (periodic_count == 3)
        queue_print("[Timer] periodic tick 3 (350 ms)", 0);

    if (periodic_count >= 3) {
        queue_print("[Timer] periodic stopping after 3 ticks.", 0);
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

    g_print_queue = xQueueCreate(10, sizeof(const char *));
    if (g_print_queue == NULL) {
        puts("[FAIL] xQueueCreate(print) failed");
        while (1);
    }

    rc = xTaskCreate(printer_task, "Printer", 512, NULL, 3, NULL);
    if (rc != pdPASS) {
        puts("[FAIL] xTaskCreate(Printer) failed");
        while (1);
    }

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
