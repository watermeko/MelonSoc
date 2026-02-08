`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"
module top(
        input  clk,
        input  rst_n,
        output [5:0] leds,
        input  rxd,
        output txd,
        inout  i2c_scl,
        inout  i2c_sda,

        output sd_cs_n,
        output sd_sck,
        output sd_mosi,
        input  sd_miso,

        output [14-1:0]             ddr_addr,       //ROW_WIDTH=14
        output [3-1:0]              ddr_bank,       //BANK_WIDTH=3
        output                      ddr_cs,
        output                      ddr_ras,
        output                      ddr_cas,
        output                      ddr_we,
        output                      ddr_ck,
        output                      ddr_ck_n,
        output                      ddr_cke,
        output                      ddr_odt,
        output                      ddr_reset_n,
        output [2-1:0]              ddr_dm,         //DM_WIDTH=2
        inout [16-1:0]              ddr_dq,         //DQ_WIDTH=16
        inout [2-1:0]               ddr_dqs,        //DQS_WIDTH=2
        inout [2-1:0]               ddr_dqs_n      //DQS_WIDTH=2
    );

    wire i2c_scl_drive_low;
    wire i2c_sda_drive_low;

    // DDR3 APP 口（对接 DDR3_Memory_Interface_Top）
    wire clk_x1;

    wire [27:0]  ddr_app_addr;
    wire         ddr_app_cmd_en;
    wire [2:0]   ddr_app_cmd;
    wire         ddr_app_wren;
    wire         ddr_app_data_end;
    wire [127:0] ddr_app_data;
    wire [5:0]   ddr_app_burst_number;

    wire         ddr_app_cmd_rdy;
    wire         ddr_app_data_rdy;
    wire         ddr_app_rdata_valid;
    wire         ddr_app_rdata_end;
    wire [127:0] ddr_app_rdata;
    wire         ddr_init_calib_complete;

    SOC u_soc(
            .clk        (clk       ),
            .ddr_app_clk (clk_x1    ),
            .rst_n      (rst_n     ),
            .leds       (leds      ),
            .rxd        (rxd       ),
            .txd        (txd       ),
            .i2c_scl    (i2c_scl   ),
            .i2c_sda    (i2c_sda   ),
            .spi_cs_n(sd_cs_n),
            .spi_sck(sd_sck),
            .spi_mosi(sd_mosi),
            .spi_miso(sd_miso),

            .ddr_app_addr(ddr_app_addr),
            .ddr_app_cmd_en(ddr_app_cmd_en),
            .ddr_app_cmd(ddr_app_cmd),
            .ddr_app_cmd_rdy(ddr_app_cmd_rdy),

            .ddr_app_wren(ddr_app_wren),
            .ddr_app_data_end(ddr_app_data_end),
            .ddr_app_data(ddr_app_data),
            .ddr_app_data_rdy(ddr_app_data_rdy),

            .ddr_app_rdata_valid(ddr_app_rdata_valid),
            .ddr_app_rdata_end(ddr_app_rdata_end),
            .ddr_app_rdata(ddr_app_rdata),

            .ddr_init_calib_complete(ddr_init_calib_complete),
            .ddr_app_burst_number(ddr_app_burst_number)
        );

    wire memory_clk;
    wire pll_lock;

    Gowin_rPLL pll(
                   .clkout(memory_clk), //output clkout
                   .lock(pll_lock), //output lock
                   .reset(~rst_n), //input reset
                   .clkin(clk) //input clkin
               );


    assign ddr_cs = 1'b0;

    //ddr3_memory_top u_ddr3 (
    DDR3_Memory_Interface_Top u_ddr3 (
                                  .clk             (clk),
                                  .memory_clk      (memory_clk),
                                  .pll_lock        (pll_lock),
                                  .rst_n           (rst_n),   //rst_n
                                  .app_burst_number(ddr_app_burst_number),
                                  .cmd_ready       (ddr_app_cmd_rdy),
                                  .cmd             (ddr_app_cmd),
                                  .cmd_en          (ddr_app_cmd_en),
                                  .addr            (ddr_app_addr),
                                  .wr_data_rdy     (ddr_app_data_rdy),
                                  .wr_data         (ddr_app_data),
                                  .wr_data_en      (ddr_app_wren),
                                  .wr_data_end     (ddr_app_data_end),
                                  .wr_data_mask    (16'h0000),
                                  .rd_data         (ddr_app_rdata),
                                  .rd_data_valid   (ddr_app_rdata_valid),
                                  .rd_data_end     (ddr_app_rdata_end),
                                  .sr_req          (1'b0),
                                  .ref_req         (1'b0),
                                  .sr_ack          (),
                                  .ref_ack         (),
                                  .init_calib_complete(ddr_init_calib_complete),
                                  .clk_out         (clk_x1),
                                  .burst           (1'b1),

                                  // mem interface
                                  .ddr_rst         (),
                                  .O_ddr_addr      (ddr_addr),
                                  .O_ddr_ba        (ddr_bank),
                                  .O_ddr_cs_n      (),
                                  .O_ddr_ras_n     (ddr_ras),
                                  .O_ddr_cas_n     (ddr_cas),
                                  .O_ddr_we_n      (ddr_we),
                                  .O_ddr_clk       (ddr_ck),
                                  .O_ddr_clk_n     (ddr_ck_n),
                                  .O_ddr_cke       (ddr_cke),
                                  .O_ddr_odt       (ddr_odt),
                                  .O_ddr_reset_n   (ddr_reset_n),
                                  .O_ddr_dqm       (ddr_dm),
                                  .IO_ddr_dq       (ddr_dq),
                                  .IO_ddr_dqs      (ddr_dqs),
                                  .IO_ddr_dqs_n    (ddr_dqs_n)
                              );
endmodule
