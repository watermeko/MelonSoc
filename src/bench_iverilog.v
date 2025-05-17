`timescale 1ns/1ps
module bench();
   reg clk;
   wire rst_n = 1; 
   wire [5:0] leds;
   reg  rxd = 1'b0;
   wire txd;

   soc u_soc(
     .clk(clk),
     .rst_n(rst_n),
     .leds(leds),
     .rxd(txd),
     .txd(txd)
   );

   reg[5:0] prev_LEDS = 0;
   initial begin
      clk = 0;
      forever begin
      #(1000.0/54.0) clk = ~clk;
         if(leds != prev_LEDS) begin
            $display("LEDS = %b",leds);
         end
         prev_LEDS <= leds;
      end
   end
endmodule   