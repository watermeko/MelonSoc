#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#define configUSE_PREEMPTION                     1
#define configUSE_TIME_SLICING                   1
#define configUSE_PORT_OPTIMISED_TASK_SELECTION  0
#define configUSE_TICKLESS_IDLE                  0

#define configCPU_CLOCK_HZ                       ( 27000000UL )
#define configTICK_RATE_HZ                       ( ( TickType_t ) 100 )

#define configMAX_PRIORITIES                     ( 4 )
#define configMINIMAL_STACK_SIZE                 ( ( unsigned short ) 256 )
#define configMAX_TASK_NAME_LEN                  ( 8 )
#define configTOTAL_HEAP_SIZE                    ( ( size_t ) ( 4 * 1024 ) )
#define configUSE_16_BIT_TICKS                   0
#define configIDLE_SHOULD_YIELD                  1

#define configISR_STACK_SIZE_WORDS               128

/*
 * MelonSoc MTIME/MTIMECMP MMIO layout (mtime_mmio.sv):
 *   0x400060 = mtime_lo,    0x400064 = mtime_hi
 *   0x400068 = mtimecmp_lo, 0x40006C = mtimecmp_hi
 * port.c reads +0/+4 for the 64-bit mtime value and writes +0/+4 for mtimecmp.
 */
#define configMTIME_BASE_ADDRESS                 ( 0x400060UL )
#define configMTIMECMP_BASE_ADDRESS              ( 0x400068UL )

#define configUSE_IDLE_HOOK                      0
#define configUSE_TICK_HOOK                      0
#define configCHECK_FOR_STACK_OVERFLOW           0
#define configUSE_MALLOC_FAILED_HOOK             0
#define configUSE_DAEMON_TASK_STARTUP_HOOK       0

#define configUSE_MUTEXES                        0
#define configUSE_RECURSIVE_MUTEXES              0
#define configUSE_COUNTING_SEMAPHORES            0
#define configUSE_TASK_NOTIFICATIONS             0
#define configUSE_QUEUE_SETS                     0
#define configQUEUE_REGISTRY_SIZE                0
#define configUSE_TIMERS                         0
#define configGENERATE_RUN_TIME_STATS            0
#define configUSE_TRACE_FACILITY                 0
#define configUSE_STATS_FORMATTING_FUNCTIONS     0
#define configUSE_NEWLIB_REENTRANT               0

#define configSUPPORT_DYNAMIC_ALLOCATION         1
#define configSUPPORT_STATIC_ALLOCATION          0

#define configTASK_RETURN_ADDRESS                0

#define configASSERT( x )   if( ( x ) == 0 ) { for( ;; ); }

#define INCLUDE_vTaskDelay                       1
#define INCLUDE_vTaskDelete                      0
#define INCLUDE_vTaskSuspend                     0
#define INCLUDE_vTaskPrioritySet                 0
#define INCLUDE_uxTaskPriorityGet                0
#define INCLUDE_vTaskDelayUntil                  0
#define INCLUDE_xTaskGetSchedulerState           0
#define INCLUDE_xTaskGetCurrentTaskHandle        0
#define INCLUDE_uxTaskGetStackHighWaterMark      0
#define INCLUDE_xTaskGetIdleTaskHandle           0
#define INCLUDE_eTaskGetState                    0
#define INCLUDE_xResumeFromISR                   0
#define INCLUDE_xTaskAbortDelay                  0
#define INCLUDE_xTaskGetHandle                   0
#define INCLUDE_xTaskResumeFromISR               0

#endif
