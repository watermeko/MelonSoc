// SPDX-License-Identifier: BSD-2-Clause

#include <sbi/riscv_io.h>
#include <sbi/sbi_console.h>
#include <sbi/sbi_platform.h>
#include <sbi_utils/timer/aclint_mtimer.h>

#define MELONSOC_UART_DATA       0x00400008UL
#define MELONSOC_UART_CTRL       0x00400010UL
#define MELONSOC_UART_RX_VALID   (1U << 0)
#define MELONSOC_UART_TX_READY   (1U << 8)

#define MELONSOC_CLINT_BASE      0x00400000UL
#define MELONSOC_MTIMECMP_ADDR   (MELONSOC_CLINT_BASE + 0x4000)
#define MELONSOC_MTIME_ADDR      (MELONSOC_CLINT_BASE + 0xbff8)
#define MELONSOC_TIMEBASE_FREQ   27000000UL

static void melonsoc_console_putc(char ch)
{
	while (!(readl((void *)MELONSOC_UART_CTRL) & MELONSOC_UART_TX_READY))
		;
	writel((u32)(u8)ch, (void *)MELONSOC_UART_DATA);
}

static int melonsoc_console_getc(void)
{
	if (!(readl((void *)MELONSOC_UART_CTRL) & MELONSOC_UART_RX_VALID))
		return -1;

	return readl((void *)MELONSOC_UART_DATA) & 0xff;
}

static struct sbi_console_device melonsoc_console = {
	.name = "melonsoc-uart",
	.console_putc = melonsoc_console_putc,
	.console_getc = melonsoc_console_getc,
};

static struct aclint_mtimer_data melonsoc_mtimer = {
	.mtime_freq = MELONSOC_TIMEBASE_FREQ,
	.mtime_addr = MELONSOC_MTIME_ADDR,
	.mtime_size = 8,
	.mtimecmp_addr = MELONSOC_MTIMECMP_ADDR,
	.mtimecmp_size = 8,
	.first_hartid = 0,
	.hart_count = 1,
	.has_64bit_mmio = false,
};

static int melonsoc_early_init(bool cold_boot)
{
	if (cold_boot)
		sbi_console_set_device(&melonsoc_console);
	return 0;
}

static int melonsoc_timer_init(void)
{
	return aclint_mtimer_cold_init(&melonsoc_mtimer, NULL);
}

const struct sbi_platform_operations platform_ops = {
	.early_init = melonsoc_early_init,
	.timer_init = melonsoc_timer_init,
};

const struct sbi_platform platform = {
	.opensbi_version = OPENSBI_VERSION,
	.platform_version = SBI_PLATFORM_VERSION(0, 1),
	.name = "MelonSoc",
	.features = SBI_PLATFORM_DEFAULT_FEATURES,
	.hart_count = 1,
	.hart_stack_size = SBI_PLATFORM_DEFAULT_HART_STACK_SIZE,
	.heap_size = SBI_PLATFORM_DEFAULT_HEAP_SIZE(1),
	.platform_ops_addr = (unsigned long)&platform_ops,
};
