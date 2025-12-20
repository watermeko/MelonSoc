`ifndef MELONSOC_SOC_PKG_SV
`define MELONSOC_SOC_PKG_SV

package soc_pkg;
  localparam int unsigned XLEN = 32;

  // ---------------- Address map (byte addresses) ----------------
  localparam logic [XLEN-1:0] IO_BASE_ADDR       = 32'h0040_0000; // 0x400000
  localparam logic [XLEN-1:0] IO_LEDS_ADDR       = IO_BASE_ADDR + 32'h0000_0004;
  localparam logic [XLEN-1:0] IO_UART_DAT_ADDR   = IO_BASE_ADDR + 32'h0000_0008;
  localparam logic [XLEN-1:0] IO_UART_CTRL_ADDR  = IO_BASE_ADDR + 32'h0000_0010;

  // Treat a 4KB page as the MMIO window.
  localparam logic [XLEN-1:0] MMIO_REGION_MASK   = 32'hFFFF_F000;
  localparam logic [XLEN-1:0] MMIO_REGION_BASE   = IO_BASE_ADDR & MMIO_REGION_MASK;

  function automatic logic [XLEN-1:0] align_word(input logic [XLEN-1:0] addr);
    return {addr[XLEN-1:2], 2'b00};
  endfunction

  function automatic logic is_mmio_region(input logic [XLEN-1:0] addr);
    return ((addr & MMIO_REGION_MASK) == MMIO_REGION_BASE);
  endfunction

  // ---------------- UART register bits ----------------
  localparam int unsigned UART_RX_VALID_BIT     = 0;
  localparam int unsigned UART_RX_OVERRUN_BIT   = 1;
  localparam int unsigned UART_RX_FRAMEERR_BIT  = 2;
  localparam int unsigned UART_TX_READY_BIT     = 8;
  localparam int unsigned UART_TX_BUSY_BIT      = 9;

  // ---------------- Global configuration ----------------
  localparam int unsigned CLK_FREQ_HZ          = 27_000_000;
  localparam int unsigned UART_BAUD            = 115200;
  localparam int unsigned UART_RX_FIFO_DEPTH   = 16;

  // ---------------- Memory configuration ----------------
  localparam int unsigned PROGROM_WORDS        = 8192; // 32KB / 4
  localparam int unsigned DATARAM_WORDS        = 8192; // 32KB / 4
endpackage

`endif
