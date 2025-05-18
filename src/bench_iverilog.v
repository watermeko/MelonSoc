`timescale 1ns/1ps
module bench();
    reg clk;
    reg rst_n_reg; // Changed to reg to control it
    wire [5:0] leds;
    reg  rxd_tb;    // Renamed to avoid confusion, drives soc.rxd
    wire txd_tb;    // Driven by soc.txd

    assign rst_n = rst_n_reg; // Connect the reg to the wire input of soc

    SOC u_soc(
      .clk(clk),
      .rst_n(rst_n),      // Use the wire rst_n
      .leds(leds),
      .rxd(rxd_tb),     // Corrected: soc input rxd driven by testbench reg
      .txd(txd_tb)      // Corrected: soc output txd drives testbench wire
    );

    reg[5:0] prev_LEDS = 6'bxxxxxx; // Initialize with X to catch the first actual value

    initial begin
        clk = 0;
        rst_n_reg = 0;    // Assert reset (active low)
        rxd_tb = 1'b0;    // Initialize rxd_tb
        #20;              // Hold reset for 20ns (adjust as needed)
        rst_n_reg = 1;    // De-assert reset
        #5;               // Wait a bit after reset release

        forever begin
            #(1000.0/54.0) clk = ~clk; // Approx 18.5185 ns period for 54MHz
            // Display logic moved to an always block or kept here carefully
            // If prev_LEDS update and display are in the same block, timing matters.
        end
    end

    // It's often better to monitor signals in a separate always block
    // or use $monitor. For this specific display:
    always @(posedge clk) begin
        if (rst_n_reg == 1'b1) begin // Start checking only after reset is released
            if (leds !== prev_LEDS) begin // Use !== for comparison with X
                $display("T=%0t, LEDS = %b (prev_LEDS = %b)", $time, leds, prev_LEDS);
            end
            prev_LEDS <= leds; // Use non-blocking assignment
        end else begin
            prev_LEDS <= 6'bxxxxxx; // Keep prev_LEDS as X during reset
        end
    end

    // Add a timeout for the simulation if it truly hangs
    initial begin
        #200000; // Stop simulation after 200us if it hasn't finished
        $display("Simulation timed out!");
        $finish;
    end

endmodule