module soc (
   input  clk,        
   input  rst_n,      
   output [5:0] leds, 
   input  rxd,        
   output txd         
);

wire slow_clk;
// ---------------MODULE-----------------

clockworks #(
  .SLOW(0)
) clk_div (
  .clk(clk),
  .slow_clk(slow_clk)
);

mem u_mem (
  .clk(slow_clk),
  .mem_addr(mem_addr),
  .mem_rdata(mem_rdata),
  .mem_ren(mem_ren)
  ,.mem_wdata(mem_wdata),
  .mem_wmask(mem_wmask)
);

wire [31:0] mem_addr;
wire [31:0] mem_rdata;
wire mem_ren;
wire [31:0] mem_wdata;
wire [3:0] mem_wmask;
wire [31:0] x10;
cpu u_cpu (
  .clk(slow_clk),
  .rst_n(rst_n),
  .mem_addr(mem_addr),
  .mem_rdata(mem_rdata),
  .mem_ren(mem_ren),
  .mem_wdata(mem_wdata),
  .mem_wmask(mem_wmask),
  .x10(x10)
);
assign leds = x10[5:0];
assign txd  = 1'b0; // not used for now

endmodule