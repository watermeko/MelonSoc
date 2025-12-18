`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"
module top(
  input  clk,        // system clock
  input  rst_n,      // reset button
  output [5:0] leds, // system LEDs
  input  rxd,        // UART receive
  output txd         // UART transmit
);

SOC u_soc(
    .clk        (clk       ),
    .rst_n      (rst_n     ),
    .leds       (leds      ),
    .rxd        (rxd       ),
    .txd        (txd       )
);
endmodule
