//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.11.02 (64-bit)
//Part Number: GW2A-LV18PG256C8/I7
//Device: GW2A-18
//Device Version: C
//Created Time: Mon May 19 16:35:52 2025

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

    Gowin_MULT your_instance_name(
        .dout(dout), //output [63:0] dout
        .a(a), //input [31:0] a
        .b(b), //input [31:0] b
        .ce(ce), //input ce
        .clk(clk), //input clk
        .reset(reset) //input reset
    );

//--------Copy end-------------------
