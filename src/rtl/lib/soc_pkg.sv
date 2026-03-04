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

            // MTIME
            localparam logic [31:0] IO_MTIME_LO_ADDR    = IO_BASE_ADDR + 32'h0000_0060;
            localparam logic [31:0] IO_MTIME_HI_ADDR    = IO_BASE_ADDR + 32'h0000_0064;
            localparam logic [31:0] IO_MTIMECMP_LO_ADDR = IO_BASE_ADDR + 32'h0000_0068;
            localparam logic [31:0] IO_MTIMECMP_HI_ADDR = IO_BASE_ADDR + 32'h0000_006C;

            // DDR3 APP（参考 ref/src/ddr3_syn_top.v 的 app_* 接口）
            // CTRL   @ IO_DDR_CTRL_ADDR:
            //   [0] START（脉冲触发一次操作）, [1] WRITE（1=写,0=读）
            //   [2] CLR_DONE, [3] CLR_ERR
            // STATUS @ IO_DDR_STATUS_ADDR:
            //   [0] PRESENT, [1] INIT_CALIB_COMPLETE, [2] BUSY, [3] DONE, [4] ERR
            //   [5] CMD_RDY, [6] WR_DATA_RDY, [7] RD_DATA_VALID（实时反映）
            // ADDR   @ IO_DDR_ADDR_ADDR: 28-bit app addr（单位依 DDR IP 定义，常见为 2Bytes）
            // BURST  @ IO_DDR_BURST_ADDR: burst_number（目前仅支持 0 = 单次 128-bit）
            // WDATA0..3 / RDATA0..3: 128-bit 数据（4x32）
            localparam logic [31:0] IO_DDR_CTRL_ADDR    = IO_BASE_ADDR + 32'h0000_0100;
            localparam logic [31:0] IO_DDR_STATUS_ADDR  = IO_BASE_ADDR + 32'h0000_0104;
            localparam logic [31:0] IO_DDR_ADDR_ADDR    = IO_BASE_ADDR + 32'h0000_0108;
            localparam logic [31:0] IO_DDR_BURST_ADDR   = IO_BASE_ADDR + 32'h0000_010C;
            localparam logic [31:0] IO_DDR_WDATA0_ADDR  = IO_BASE_ADDR + 32'h0000_0110;
            localparam logic [31:0] IO_DDR_WDATA1_ADDR  = IO_BASE_ADDR + 32'h0000_0114;
            localparam logic [31:0] IO_DDR_WDATA2_ADDR  = IO_BASE_ADDR + 32'h0000_0118;
            localparam logic [31:0] IO_DDR_WDATA3_ADDR  = IO_BASE_ADDR + 32'h0000_011C;
            localparam logic [31:0] IO_DDR_RDATA0_ADDR  = IO_BASE_ADDR + 32'h0000_0120;
            localparam logic [31:0] IO_DDR_RDATA1_ADDR  = IO_BASE_ADDR + 32'h0000_0124;
            localparam logic [31:0] IO_DDR_RDATA2_ADDR  = IO_BASE_ADDR + 32'h0000_0128;
            localparam logic [31:0] IO_DDR_RDATA3_ADDR  = IO_BASE_ADDR + 32'h0000_012C;

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
