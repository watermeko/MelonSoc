`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"
module gpio_mmio #(
  parameter int unsigned LEDS_W = 6
) (
  input  logic clk,
  input  logic rst_n,
  simple_bus_if.slave bus,
  output logic [LEDS_W-1:0] leds
);
  import soc_pkg::*;

  logic sel_leds;
  always_comb begin
    sel_leds = (align_word(bus.addr) == IO_LEDS_ADDR);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      leds <= '0;
    end else if (bus.wen && sel_leds && (|bus.wstrb)) begin
      leds <= bus.wdata[LEDS_W-1:0];
    end
  end

  always_comb begin
    if (sel_leds) begin
      bus.rdata = {{(32-LEDS_W){1'b0}}, leds};
    end else begin
      bus.rdata = 32'b0;
    end
  end
endmodule
