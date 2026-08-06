`ifndef MELONSOC_SOC_PKG_SV
`define MELONSOC_SOC_PKG_SV

        package soc_pkg;

            localparam logic [31:0] IO_BASE_ADDR       = 32'h0040_0000; // 0x400000

            // GPIO
            localparam logic [31:0] IO_LEDS_ADDR       = IO_BASE_ADDR + 32'h0000_0004;

            // UART
            localparam logic [31:0] IO_UART_DAT_ADDR   = IO_BASE_ADDR + 32'h0000_0008;
            localparam logic [31:0] IO_UART_CTRL_ADDR  = IO_BASE_ADDR + 32'h0000_0010;

            // I2C
            localparam logic [31:0] IO_I2C_TXRX_ADDR   = IO_BASE_ADDR + 32'h0000_0020;
            localparam logic [31:0] IO_I2C_CMD_ADDR    = IO_BASE_ADDR + 32'h0000_0024;
            localparam logic [31:0] IO_I2C_STATUS_ADDR = IO_BASE_ADDR + 32'h0000_0028;
            localparam logic [31:0] IO_I2C_DIV_ADDR    = IO_BASE_ADDR + 32'h0000_002C;

            // TIMER
            localparam logic [31:0] IO_TIMER_CTRL_ADDR   = IO_BASE_ADDR + 32'h0000_0030;
            localparam logic [31:0] IO_TIMER_PRESC_ADDR  = IO_BASE_ADDR + 32'h0000_0034;
            localparam logic [31:0] IO_TIMER_COUNT_ADDR  = IO_BASE_ADDR + 32'h0000_0038;
            localparam logic [31:0] IO_TIMER_CMP_ADDR    = IO_BASE_ADDR + 32'h0000_003C;
            localparam logic [31:0] IO_TIMER_PERIOD_ADDR = IO_BASE_ADDR + 32'h0000_0040;
            localparam logic [31:0] IO_TIMER_STATUS_ADDR = IO_BASE_ADDR + 32'h0000_0044;

            // SPI
            localparam logic [31:0] IO_SPI_TXRX_ADDR   = IO_BASE_ADDR + 32'h0000_0050;
            localparam logic [31:0] IO_SPI_CTRL_ADDR   = IO_BASE_ADDR + 32'h0000_0054;
            localparam logic [31:0] IO_SPI_STATUS_ADDR = IO_BASE_ADDR + 32'h0000_0058;
            localparam logic [31:0] IO_SPI_DIV_ADDR    = IO_BASE_ADDR + 32'h0000_005C;

            // Native SD host
            localparam logic [31:0] IO_SD_CMD_ADDR     = IO_BASE_ADDR + 32'h0000_0060;
            localparam logic [31:0] IO_SD_ARG_ADDR     = IO_BASE_ADDR + 32'h0000_0064;
            localparam logic [31:0] IO_SD_CTRL_ADDR    = IO_BASE_ADDR + 32'h0000_0068;
            localparam logic [31:0] IO_SD_RESP0_ADDR   = IO_BASE_ADDR + 32'h0000_006C;
            localparam logic [31:0] IO_SD_DEBUG_ADDR   = IO_BASE_ADDR + 32'h0000_0070;
            localparam logic [31:0] IO_SD_CRC_ADDR     = IO_BASE_ADDR + 32'h0000_0074;
            localparam logic [31:0] IO_SD_DATA_ADDR    = IO_BASE_ADDR + 32'h0000_0080;

            // CLINT (Core Local Interruptor) — standard SiFive layout
            localparam logic [31:0] IO_CLINT_BASE_ADDR   = IO_BASE_ADDR;
            localparam logic [31:0] IO_CLINT_MSIP_ADDR   = IO_CLINT_BASE_ADDR + 32'h0000_0000;  // hart 0
            localparam logic [31:0] IO_CLINT_MTIMECMP_ADDR = IO_CLINT_BASE_ADDR + 32'h0000_4000; // hart 0, lo
            localparam logic [31:0] IO_CLINT_MTIME_ADDR  = IO_CLINT_BASE_ADDR + 32'h0000_BFF8;  // 64-bit timer

            localparam logic [31:0] DDR_BASE_ADDR      = 32'h8000_0000;
            localparam logic [31:0] DDR_SIZE_BYTES     = 32'h0800_0000; // 1Gbit = 128MiB
            localparam logic [31:0] DDR_END_ADDR       = DDR_BASE_ADDR + DDR_SIZE_BYTES;
            localparam int unsigned PROGROM_WORDS     = 7168; // 28KB / 4
            localparam int unsigned DATARAM_WORDS     = 4096; // 16KB / 4
            localparam logic [31:0] DATARAM_BASE_ADDR  = 32'h0001_0000;
            localparam logic [31:0] DATARAM_SIZE_BYTES = DATARAM_WORDS * 4;
            localparam logic [31:0] DATARAM_END_ADDR   = DATARAM_BASE_ADDR + DATARAM_SIZE_BYTES;


            // 地址的第高20位用于区分外设区域
            localparam logic [31:0] MMIO_REGION_MASK   = 32'hFFFF_0000;
            localparam logic [31:0] MMIO_REGION_BASE   = IO_BASE_ADDR & MMIO_REGION_MASK;

            // 字节地址到字地址
            function automatic logic [31:0] align_word(input logic [31:0] addr);
                return {addr[31:2], 2'b00};
            endfunction

            function automatic logic is_mmio_region(input logic [31:0] addr);
                return ((addr & MMIO_REGION_MASK) == MMIO_REGION_BASE);
            endfunction

            function automatic logic is_ddr_region(input logic [31:0] addr);
                return (addr >= DDR_BASE_ADDR) && (addr < DDR_END_ADDR);
            endfunction

            function automatic logic is_dataram_region(input logic [31:0] addr);
                return (addr >= DATARAM_BASE_ADDR) && (addr < DATARAM_END_ADDR);
            endfunction

            function automatic logic is_mapped_mmio(input logic [31:0] addr);
                logic [31:0] word_addr;
                word_addr = align_word(addr);
                return (word_addr == IO_LEDS_ADDR) ||
                       (word_addr == IO_UART_DAT_ADDR) ||
                       (word_addr == IO_UART_CTRL_ADDR) ||
                       ((word_addr >= IO_I2C_TXRX_ADDR) && (word_addr <= IO_I2C_DIV_ADDR)) ||
                       ((word_addr >= IO_TIMER_CTRL_ADDR) && (word_addr <= IO_TIMER_STATUS_ADDR)) ||
                       ((word_addr >= IO_SPI_TXRX_ADDR) && (word_addr <= IO_SPI_DIV_ADDR)) ||
                       ((word_addr >= IO_SD_CMD_ADDR) && (word_addr <= IO_SD_CRC_ADDR)) ||
                       ((word_addr >= IO_SD_DATA_ADDR) && (word_addr < (IO_SD_DATA_ADDR + 32'd512))) ||
                       (word_addr == IO_CLINT_MSIP_ADDR) ||
                       (word_addr == IO_CLINT_MTIMECMP_ADDR) ||
                       (word_addr == (IO_CLINT_MTIMECMP_ADDR + 4)) ||
                       (word_addr == IO_CLINT_MTIME_ADDR) ||
                       (word_addr == (IO_CLINT_MTIME_ADDR + 4));
            endfunction

            function automatic logic is_mapped_data_address(input logic [31:0] addr);
                return is_dataram_region(addr) || is_ddr_region(addr) || is_mapped_mmio(addr);
            endfunction

            function automatic logic supports_atomic(input logic [31:0] addr);
                return is_dataram_region(addr) || is_ddr_region(addr);
            endfunction

            localparam int unsigned UART_RX_VALID_BIT     = 0;
            localparam int unsigned UART_RX_OVERRUN_BIT   = 1;
            localparam int unsigned UART_RX_FRAMEERR_BIT  = 2;
            localparam int unsigned UART_TX_READY_BIT     = 8;
            localparam int unsigned UART_TX_BUSY_BIT      = 9;

            localparam int unsigned UART_BAUD_RATE            = 115200;

            localparam int unsigned CLK_FREQ_HZ          = 27_000_000;
        endpackage

`endif
