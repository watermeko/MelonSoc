//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: IP file
//Tool Version: V1.9.11.02 (64-bit)
//Part Number: GW2A-LV18PG256C8/I7
//Device: GW2A-18
//Device Version: C
//Created Time: Mon May 19 16:35:52 2025

module Gowin_MULT (dout, a, b, ce, clk, reset);

output [63:0] dout;
input [31:0] a;
input [31:0] b;
input ce;
input clk;
input reset;

wire [7:0] dout_w;
wire gw_vcc;

assign gw_vcc = 1'b1;

MULT36X36 mult36x36_inst (
    .DOUT({dout_w[7:0],dout[63:0]}),
    .A({a[31],a[31],a[31],a[31],a[31:0]}),
    .B({b[31],b[31],b[31],b[31],b[31:0]}),
    .ASIGN(gw_vcc),
    .BSIGN(gw_vcc),
    .CE(ce),
    .CLK(clk),
    .RESET(reset)
);

defparam mult36x36_inst.AREG = 1'b1;
defparam mult36x36_inst.BREG = 1'b1;
defparam mult36x36_inst.OUT0_REG = 1'b1;
defparam mult36x36_inst.PIPE_REG = 1'b0;
defparam mult36x36_inst.ASIGN_REG = 1'b0;
defparam mult36x36_inst.BSIGN_REG = 1'b0;
defparam mult36x36_inst.MULT_RESET_MODE = "SYNC";

endmodule //Gowin_MULT
