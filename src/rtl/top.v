`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"
`include "ip/video_pll/video_pll.v"
`include "peripheral/lcd_dma.sv"
module top(
        input  clk,
        input  rst_n,
        output [5:0] leds,
        input  rxd,
        output txd,
        inout  i2c_scl,
        inout  i2c_sda,

        inout  sd_cs_n,
        output sd_sck,
        inout  sd_mosi,
        inout  sd_miso,

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
        inout [2-1:0]               ddr_dqs_n,      //DQS_WIDTH=2

        // RGB565 480x272 LCD panel
        output              lcd_dclk,
        output              lcd_hs,
        output              lcd_vs,
        output              lcd_de,
        output [4:0]        lcd_r,
        output [5:0]        lcd_g,
        output [4:0]        lcd_b
    );

    wire i2c_scl_drive_low;
    wire i2c_sda_drive_low;

    // DDR3 APP 口（对接 DDR3_Memory_Interface_Top）
    wire clk_x1;

    // CPU-side APP signals (from ddr3_wb_bridge inside SOC)
    wire [27:0]  cpu_app_addr;
    wire         cpu_app_cmd_en;
    wire [2:0]   cpu_app_cmd;
    wire         cpu_app_cmd_rdy;
    wire         cpu_app_rdata_valid;
    wire         cpu_app_rdata_end;
    wire [127:0] cpu_app_rdata;
    wire [5:0]   cpu_app_burst_number;
    wire         cpu_app_idle;
    wire         cpu_app_lock;

    // Common (DDR3 IP inputs) APP signals driven by the arbiter
    wire [27:0]  ddr_app_addr;
    wire         ddr_app_cmd_en;
    wire [2:0]   ddr_app_cmd;
    wire         ddr_app_wren;
    wire         ddr_app_data_end;
    wire [127:0] ddr_app_data;
    wire [5:0]   ddr_app_burst_number;

    wire         ddr_app_cmd_rdy_arb;   // IP cmd_ready, fanned back by arbiter
    wire         ddr_app_data_rdy;
    wire         ddr_app_rdata_valid;
    wire         ddr_app_rdata_end;
    wire [127:0] ddr_app_rdata;
    wire         ddr_init_calib_complete;

    // CPU-side APP outputs (from ddr3_wb_bridge inside SOC)
    wire         cpu_app_wren_out;
    wire         cpu_app_data_end_out;
    wire [127:0] cpu_app_data_out;

    // LCD-side APP signals
    wire [27:0]  lcd_app_addr;
    wire         lcd_app_cmd_en;
    wire [2:0]   lcd_app_cmd;
    wire         lcd_app_cmd_rdy;
    wire         lcd_app_rdata_valid;
    wire [127:0] lcd_app_rdata;
    wire [5:0]   lcd_app_burst_number;  // unused but driven by DMA

    // Pixel clock for the LCD (~9 MHz from the 27 MHz board clock).
    wire memory_clk;
    wire pll_lock;
    wire lcd_dclk_int;
    wire lcd_pll_lock;
    wire soc_rst_n;
    wire soc_async_rst_n;
    logic [7:0] soc_reset_sync;
    logic [18:0] lcd_start_ctr = '0;
    logic        lcd_rst_n = 1'b0;

    video_pll u_video_pll (
        .clkin (clk),
        .lock  (lcd_pll_lock),
        .clkout(lcd_dclk_int)
    );
    assign lcd_dclk = lcd_dclk_int;
    assign soc_async_rst_n = rst_n;

    // Assert reset immediately, then release it synchronously in the 27 MHz
    // clock domain that drives the CPU and peripherals.
    always_ff @(posedge clk or negedge soc_async_rst_n) begin
        if (!soc_async_rst_n)
            soc_reset_sync <= 8'b0;
        else
            soc_reset_sync <= {soc_reset_sync[6:0], 1'b1};
    end
    assign soc_rst_n = soc_reset_sync[7];

    wire spi_cs_n_unused;
    wire spi_sck_unused;
    wire spi_mosi_unused;
    wire sdclk_native;
    wire [3:0] sddat_native;

    assign sd_sck = sdclk_native;
    assign sd_miso = 1'bz;
    assign sddat_native[0] = sd_miso;
    assign sddat_native[1] = 1'b1;
    assign sddat_native[2] = 1'b1;
    assign sd_cs_n = 1'bz;
    assign sddat_native[3] = sd_cs_n;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lcd_start_ctr <= '0;
            lcd_rst_n <= 1'b0;
        end
        else if (lcd_start_ctr != {19{1'b1}}) begin
            lcd_start_ctr <= lcd_start_ctr + 19'd1;
            lcd_rst_n <= 1'b0;
        end
        else begin
            lcd_rst_n <= 1'b1;
        end
    end

    SOC u_soc(
            .clk        (clk         ),
            .ddr_app_clk (clk_x1    ),
            .rst_n      (soc_rst_n),
            .leds       (leds      ),
            .rxd        (rxd       ),
            .txd        (txd       ),
            .i2c_scl    (i2c_scl   ),
            .i2c_sda    (i2c_sda   ),
            .spi_cs_n(spi_cs_n_unused),
            .spi_sck(spi_sck_unused),
            .spi_mosi(spi_mosi_unused),
            .spi_miso(1'b1),
            .sdclk(sdclk_native),
            .sdcmd(sd_mosi),
            .sddat(sddat_native),

            .ddr_app_addr(cpu_app_addr),
            .ddr_app_cmd_en(cpu_app_cmd_en),
            .ddr_app_cmd(cpu_app_cmd),
            .ddr_app_cmd_rdy(cpu_app_cmd_rdy),

            .ddr_app_wren(cpu_app_wren_out),
            .ddr_app_data_end(cpu_app_data_end_out),
            .ddr_app_data(cpu_app_data_out),
            .ddr_app_data_rdy(ddr_app_data_rdy),

            .ddr_app_rdata_valid(cpu_app_rdata_valid),
            .ddr_app_rdata_end(cpu_app_rdata_end),
            .ddr_app_rdata(cpu_app_rdata),

            .ddr_init_calib_complete(ddr_init_calib_complete),
            .ddr_app_burst_number(cpu_app_burst_number),
            .ddr_app_idle(cpu_app_idle),
            .ddr_app_lock(cpu_app_lock)
        );

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
                                  .cmd_ready       (ddr_app_cmd_rdy_arb),
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

    // ---- LCD framebuffer DMA -> DDR APP (read-only, scavenger) -----------
    lcd_dma u_lcd_dma (
        .app_clk              (clk_x1),
        .rst_n                (lcd_rst_n),
        .init_calib_complete  (ddr_init_calib_complete),
        .app_addr             (lcd_app_addr),
        .app_cmd_en           (lcd_app_cmd_en),
        .app_cmd              (lcd_app_cmd),
        .app_cmd_rdy          (lcd_app_cmd_rdy),
        .app_rdata_valid      (lcd_app_rdata_valid),
        .app_rdata            (lcd_app_rdata),
        .app_burst_number     (lcd_app_burst_number),
        .pix_clk              (lcd_dclk_int),
        .pix_rst              (~lcd_rst_n | ~lcd_pll_lock),
        .lcd_hs               (lcd_hs),
        .lcd_vs               (lcd_vs),
        .lcd_de               (lcd_de),
        .lcd_r                (lcd_r),
        .lcd_g                (lcd_g),
        .lcd_b                (lcd_b)
    );

    // ---- DDR APP arbiter: CPU priority, LCD scavenger ---------------------
    // The CPU's ddr3_wb_bridge declares app_idle when its APP FSM is idle with
    // no in-flight request. When the LCD DMA is granted, it keeps the APP port
    // for a burst window (>= several beats) so it can sustain the ~9 MHz pixel
    // stream; the CPU is simply stalled (cmd_rdy=0) during that window, which
    // is safe because the CPU bridge holds its request until serviced.
    //
    // Read-data ownership is tracked by an in-flight command counter: a beat
    // read issued while LCD was granted returns to the LCD; otherwise to CPU.
    logic lcd_grant;
    logic [1:0] inflight_lcd;   // outstanding LCD read beats (0..2)
    wire lcd_issue  = lcd_grant && lcd_app_cmd_en && lcd_app_cmd_rdy;
    wire lcd_retire = ddr_app_rdata_valid && (inflight_lcd != 0);
    logic cpu_app_lock_meta;
    logic cpu_app_lock_sync;

    always_ff @(posedge clk_x1 or negedge lcd_rst_n) begin
        if (!lcd_rst_n) begin
            cpu_app_lock_meta <= 1'b0;
            cpu_app_lock_sync <= 1'b0;
        end
        else begin
            cpu_app_lock_meta <= cpu_app_lock;
            cpu_app_lock_sync <= cpu_app_lock_meta;
        end
    end

    always_ff @(posedge clk_x1 or negedge lcd_rst_n) begin
        if (!lcd_rst_n) begin
            lcd_grant     <= 1'b0;
            inflight_lcd  <= 2'd0;
        end
        else begin
            // grant/handoff
            if (!lcd_grant)
                lcd_grant <= !cpu_app_lock_sync && cpu_app_idle && (inflight_lcd == 0) && lcd_app_cmd_en;
            // release when no LCD beat is in flight and LCD no longer requests
            else if (inflight_lcd == 0 && (!lcd_app_cmd_en || cpu_app_lock_sync))
                lcd_grant <= 1'b0;

            // count outstanding LCD beats: issue when (lcd_grant & cmd_en & rdy)
            //      retire when a beat returns tagged LCD
            if (lcd_issue && !lcd_retire)
                inflight_lcd <= inflight_lcd + 2'd1;
            else if (!lcd_issue && lcd_retire)
                inflight_lcd <= inflight_lcd - 2'd1;
        end
    end

    // command/address toward DDR3: CPU when not granting LCD, else LCD
    assign ddr_app_cmd_en = lcd_grant ? lcd_app_cmd_en   : cpu_app_cmd_en;
    assign ddr_app_cmd    = lcd_grant ? lcd_app_cmd      : cpu_app_cmd;
    assign ddr_app_addr   = lcd_grant ? lcd_app_addr     : cpu_app_addr;

    // burst number toward the IP: whichever master is granted.
    assign ddr_app_burst_number = lcd_grant ? lcd_app_burst_number : cpu_app_burst_number;

    // cmd_ready fed back to each master: only the granted one sees ready.
    assign cpu_app_cmd_rdy       = lcd_grant ? 1'b0 : ddr_app_cmd_rdy_arb;
    assign lcd_app_cmd_rdy       = lcd_grant ? ddr_app_cmd_rdy_arb : 1'b0;

    // write side belongs to the CPU bridge only (DMA never writes).
    assign ddr_app_wren        = cpu_app_wren_out;
    assign ddr_app_data_end    = cpu_app_data_end_out;
    assign ddr_app_data        = cpu_app_data_out;

    // read-data routing by the in-flight LCD count: a returning beat is tagged
    // LCD iff it was issued under LCD grant and not yet retired.
    wire beat_is_lcd = (inflight_lcd != 0) && ddr_app_rdata_valid;
    assign cpu_app_rdata_valid  = ddr_app_rdata_valid & ~beat_is_lcd;
    assign lcd_app_rdata_valid  = ddr_app_rdata_valid &  beat_is_lcd;
    assign cpu_app_rdata        = ddr_app_rdata;
    assign lcd_app_rdata        = ddr_app_rdata;
    assign cpu_app_rdata_end    = ddr_app_rdata_end;
endmodule
