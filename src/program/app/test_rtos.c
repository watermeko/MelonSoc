#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
#include "timers.h"
#include "test_rtos.h"

extern int puts(const char *s);

/* ---- periodic ping/pong tasks -------------------------------------------- */

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

/* ---- vTaskDelete demo — task that deletes itself ------------------------ */

static void task_self_delete(void *param)
{
    (void)param;
    puts("[TaskC] Hello — I will delete myself now.");
    vTaskDelete(NULL);
    /* never reached */
}

/* ---- software timer callbacks -------------------------------------------- */

static void timer_oneshot_cb(TimerHandle_t xTimer)
{
    (void)xTimer;
    puts("[Timer] one-shot fired (300 ms)");
}

static unsigned periodic_count = 0;
static void timer_periodic_cb(TimerHandle_t xTimer)
{
    (void)xTimer;
    periodic_count++;
    if (periodic_count == 1)
        puts("[Timer] periodic tick 1 (350 ms)");
    else if (periodic_count == 2)
        puts("[Timer] periodic tick 2 (350 ms)");
    else if (periodic_count == 3)
        puts("[Timer] periodic tick 3 (350 ms)");
    if (periodic_count >= 3) {
        puts("[Timer] periodic stopping after 3 ticks.");
        xTimerStop(xTimer, 0);
    }
}

/* ---- main test entry ----------------------------------------------------- */

void shell_test_rtos(const char *arg)
{
    (void)arg;

    extern void freertos_risc_v_trap_handler(void);
    uint32_t trap_addr = (uint32_t)freertos_risc_v_trap_handler;
    asm volatile("csrw mtvec, %0" :: "r"(trap_addr));

    puts("--- FreeRTOS Test ---");

    /* 1. ping/pong tasks */
    xTaskCreate(task_a, "A", configMINIMAL_STACK_SIZE, NULL, 2, NULL);
    xTaskCreate(task_b, "B", configMINIMAL_STACK_SIZE, NULL, 2, NULL);
    puts("[OK] Created TaskA (ping/200ms) and TaskB (pong/300ms)");

    /* 2. vTaskDelete: create a task that deletes itself */
    xTaskCreate(task_self_delete, "C", configMINIMAL_STACK_SIZE, NULL, 1, NULL);
    puts("[OK] Created TaskC (self-delete demo)");

    /* 3. software timers */
    TimerHandle_t t1 = xTimerCreate(
        "oneshot", pdMS_TO_TICKS(300), pdFALSE, /* one-shot */
        (void *)0, timer_oneshot_cb);
    if (t1) {
        if (xTimerStart(t1, 0) != pdPASS)
            puts("[WARN] xTimerStart(oneshot) failed");
    } else {
        puts("[WARN] xTimerCreate(oneshot) failed");
    }

    TimerHandle_t t2 = xTimerCreate(
        "periodic", pdMS_TO_TICKS(350), pdTRUE, /* auto-reload */
        (void *)0, timer_periodic_cb);
    if (t2) {
        if (xTimerStart(t2, 0) != pdPASS)
            puts("[WARN] xTimerStart(periodic) failed");
    } else {
        puts("[WARN] xTimerCreate(periodic) failed");
    }

    puts("[OK] Created one-shot timer (300 ms) and periodic timer (350 ms x3)");

    puts("Scheduler running (sim exits at max-cycles)...");

    vTaskStartScheduler();

    puts("[FAIL] Scheduler returned!");
}
