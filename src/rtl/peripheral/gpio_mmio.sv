`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"
module gpio_mmio #(
        parameter int unsigned LEDS_W = 6
    ) (
        input  logic clk,
        input  logic rst_n,
        simple_bus_if.slave bus,
        output logic [LEDS_W-1:0] leds
    );
    import soc_pkg::*;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            leds <= '0;
        end
        else if (bus.wen && (|bus.wstrb)) begin
            leds <= bus.wdata[LEDS_W-1:0];
        end
    end

    always_comb begin
        bus.rdata = {{(32-LEDS_W){1'b0}}, leds};
    end
endmodule
