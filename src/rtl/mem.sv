`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"
module mem #(
  parameter int unsigned PROGROM_WORDS = soc_pkg::PROGROM_WORDS,
  parameter int unsigned DATARAM_WORDS = soc_pkg::DATARAM_WORDS
) (
  input logic clk,
  imem_if.slave instr,
  simple_bus_if.slave data
);
  import soc_pkg::*;
  localparam int unsigned PROGROM_AW = (PROGROM_WORDS <= 1) ? 1 : $clog2(PROGROM_WORDS);
  localparam int unsigned DATARAM_AW = (DATARAM_WORDS <= 1) ? 1 : $clog2(DATARAM_WORDS);

  // Force Gowin to map these arrays into block SRAM (BSRAM) rather than LUTs.
  logic [31:0] PROGROM [0:PROGROM_WORDS-1]/*synthesis syn_ramstyle = "block_ram"*/;
  logic [31:0] DATARAM [0:DATARAM_WORDS-1]/*synthesis syn_ramstyle = "block_ram"*/;

  // Address mapping: use the low bits as word index (keeps the existing linker map).
  logic [PROGROM_AW-1:0] instr_word_addr;
  logic [DATARAM_AW-1:0] data_word_addr;
  assign instr_word_addr = instr.addr[PROGROM_AW+1:2];
  assign data_word_addr  = data.addr[DATARAM_AW+1:2];

  // Instruction read (sync)
  always_ff @(posedge clk) begin
    if (instr.ren) begin
      instr.rdata <= PROGROM[instr_word_addr];
    end
  end

  // Data read/write (sync read, same-cycle write with byte strobes)
  always_ff @(posedge clk) begin
    if (data.ren) begin
      data.rdata <= DATARAM[data_word_addr];
    end

    if (data.wen && data.wstrb[0]) DATARAM[data_word_addr][7:0]   <= data.wdata[7:0];
    if (data.wen && data.wstrb[1]) DATARAM[data_word_addr][15:8]  <= data.wdata[15:8];
    if (data.wen && data.wstrb[2]) DATARAM[data_word_addr][23:16] <= data.wdata[23:16];
    if (data.wen && data.wstrb[3]) DATARAM[data_word_addr][31:24] <= data.wdata[31:24];
  end

  // Initialization: load from hex files.
  initial begin
    `ifdef BENCH
      $readmemh("build/PROGROM.hex", PROGROM);
      $readmemh("build/DATARAM.hex", DATARAM);
    `else
      $readmemh("../build/PROGROM.hex", PROGROM);
      $readmemh("../build/DATARAM.hex", DATARAM);
    `endif

    `ifdef BENCH
      $display("[MEM] Initialized PROGROM and DATARAM");
      $display("[MEM] PROGROM[0:3] = %h %h %h %h",
               PROGROM[0], PROGROM[1], PROGROM[2], PROGROM[3]);
      $display("[MEM] DATARAM[0:3] = %h %h %h %h",
               DATARAM[0], DATARAM[1], DATARAM[2], DATARAM[3]);
    `endif
  end
endmodule
