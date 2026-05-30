`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"
module gpio_mmio #(
        parameter int unsigned LEDS_W = 6
    ) (
        input  logic clk,
        input  logic rst_n,
        wb_if.slave bus,
        output logic [LEDS_W-1:0] leds
    );
    import soc_pkg::*;
    assign bus.ack = bus.cyc && bus.stb;
    assign bus.stall = 1'b0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            leds <= '0;
        end
        else if (bus.cyc && bus.stb && bus.we && (|bus.sel)) begin
            leds <= bus.dat_w[LEDS_W-1:0];
        end
    end

    always_comb begin
        bus.dat_r = {{(32-LEDS_W){1'b0}}, leds};
    end
endmodule
