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

            // 地址的第高20位用于区分外设区域
            localparam logic [31:0] MMIO_REGION_MASK   = 32'hFFFF_F000;
            localparam logic [31:0] MMIO_REGION_BASE   = IO_BASE_ADDR & MMIO_REGION_MASK;

            // 字节地址到字地址
            function automatic logic [31:0] align_word(input logic [31:0] addr);
                return {addr[31:2], 2'b00};
            endfunction

            function automatic logic is_mmio_region(input logic [31:0] addr);
                return ((addr & MMIO_REGION_MASK) == MMIO_REGION_BASE);
            endfunction

            localparam int unsigned UART_RX_VALID_BIT     = 0;
            localparam int unsigned UART_RX_OVERRUN_BIT   = 1;
            localparam int unsigned UART_RX_FRAMEERR_BIT  = 2;
            localparam int unsigned UART_TX_READY_BIT     = 8;
            localparam int unsigned UART_TX_BUSY_BIT      = 9;

            localparam int unsigned UART_BAUD_RATE            = 115200;

            localparam int unsigned CLK_FREQ_HZ          = 27_000_000;
            localparam int unsigned PROGROM_WORDS        = 8192; // 32KB / 4
            localparam int unsigned DATARAM_WORDS        = 8192; // 32KB / 4
        endpackage

`endif
