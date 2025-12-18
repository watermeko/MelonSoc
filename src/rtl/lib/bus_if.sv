`ifndef MELONSOC_BUS_IF_SV
`define MELONSOC_BUS_IF_SV

interface imem_if #(
  parameter int unsigned ADDR_W = 32,
  parameter int unsigned DATA_W = 32
);
  logic [ADDR_W-1:0] addr;
  logic              ren;
  logic [DATA_W-1:0] rdata;

  modport master (output addr, ren, input rdata);
  modport slave  (input addr, ren, output rdata);
endinterface

interface simple_bus_if #(
  parameter int unsigned ADDR_W = 32,
  parameter int unsigned DATA_W = 32,
  parameter int unsigned STRB_W = (DATA_W / 8)
);
  logic [ADDR_W-1:0] addr;
  logic              ren;
  logic              wen;
  logic [DATA_W-1:0] wdata;
  logic [STRB_W-1:0] wstrb;
  logic [DATA_W-1:0] rdata;

  modport master (output addr, ren, wen, wdata, wstrb, input rdata);
  modport slave  (input addr, ren, wen, wdata, wstrb, output rdata);
endinterface

`endif
