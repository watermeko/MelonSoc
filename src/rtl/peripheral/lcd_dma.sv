`include "../lib/soc_pkg.sv"
`include "../peripheral/vga_timing.sv"

// LCD framebuffer DMA + RGB565 panel output, 128-bit DDR APP read path with
// ping-pong line buffers.
//
// Two line RAMs (each 480 RGB565 pixels): the DMA (app_clk) fills one buffer
// with the next framebuffer line, the panel (pix_clk, ~9 MHz) reads the other.
// At each display-line boundary the two buffers swap, so the panel always
// reads a fully-prepared line and the streaming underflow/phase-drift that a
// small circular FIFO suffers is eliminated.
//
// The module reads-only; it never asserts app_wren. The DDR APP port is
// arbitrated in the SoC top between the CPU (priority) and this DMA.
module lcd_dma #(
        parameter logic [31:0] FB_BASE   = 32'h8010_0000,
        localparam int unsigned LCD_W    = 480,
        localparam int unsigned LCD_H    = 272,
        localparam int unsigned BEAT_PIX  = 8,
        localparam int unsigned LINE_BEATS = LCD_W / BEAT_PIX // 60
    ) (
        input  logic        app_clk,
        input  logic        rst_n,
        input  logic        init_calib_complete,

        output logic [27:0] app_addr,
        output logic        app_cmd_en,
        output logic [2:0]  app_cmd,
        input  logic        app_cmd_rdy,
        input  logic        app_rdata_valid,
        input  logic [127:0] app_rdata,
        output logic [5:0]  app_burst_number,

        input  logic        pix_clk,
        input  logic        pix_rst,
        output logic        lcd_hs,
        output logic        lcd_vs,
        output logic        lcd_de,
        output logic [4:0]  lcd_r,
        output logic [5:0]  lcd_g,
        output logic [4:0]  lcd_b
    );

    localparam int unsigned LINE_BYTES = LCD_W * 2;
    localparam int unsigned FB_BYTES   = LCD_W * LCD_H * 2;

    // ---- line buffers (dual-port: write on app_clk, read on pix_clk) ----
    logic [15:0] lineA [0:LCD_W-1];
    logic [15:0] lineB [0:LCD_W-1];

    // toggle-flag handshakes across the two clock domains
    logic line_req_toggle;                    // pix_clk -> app_clk
    logic line_req_a1, line_req_a2;          // app_clk domain
    logic line_req_seen;                      // app_clk: last seen value
    logic line_ack_toggle;                    // app_clk -> pix_clk
    logic line_ack_p1, line_ack_p2;          // pix_clk domain
    logic line_ack_seen;                      // pix_clk: last seen value

    // ================= panel side (pix_clk) ============================
    logic [9:0] px_x, px_y;

    vga_timing u_vga (
        .clk      (pix_clk),
        .rst      (pix_rst),
        .hs       (lcd_hs),
        .vs       (lcd_vs),
        .de       (lcd_de),
        .active_x (px_x),
        .active_y (px_y)
    );

    // line_pulse: strobe at the first pixel of each displayed line
    logic de_d;
    logic line_pulse;
    always_ff @(posedge pix_clk or posedge pix_rst) begin
        if (pix_rst) de_d <= 1'b0;
        else         de_d <= lcd_de;
    end
    assign line_pulse = lcd_de & ~de_d;

    // which physical buffer the panel shows; swap when a new line is ready
    logic show_sel;
    wire  new_line_ready = (line_ack_p2 != line_ack_seen);
    always_ff @(posedge pix_clk or posedge pix_rst) begin
        if (pix_rst) begin
            show_sel      <= 1'b0;
            line_req_toggle <= 1'b0;
            line_ack_seen  <= 1'b0;
        end
        else begin
            if (line_pulse && new_line_ready) begin
                line_ack_seen <= line_ack_p2;
                show_sel <= ~show_sel;
                line_req_toggle <= ~line_req_toggle;
            end
        end
    end

    // read a pixel from the shown buffer
    wire [15:0] pixA = lineA[px_x];
    wire [15:0] pixB = lineB[px_x];
    wire [15:0] rd_pix = show_sel ? pixB : pixA;

    assign lcd_r = lcd_de ? rd_pix[15:11] : 5'b0;
    assign lcd_g = lcd_de ? rd_pix[10:5]  : 6'b0;
    assign lcd_b = lcd_de ? rd_pix[4:0]   : 5'b0;

    // ================= DMA side (app_clk) ==============================
    typedef enum logic [1:0] {D_IDLE, D_REQ, D_WAIT, D_PUSH} d_state_t;
    d_state_t d_st;
    logic [31:0] f_byte;          // byte addr of current beat
    logic [127:0] cap;
    logic [2:0]   pix_idx;
    logic [9:0]   beat_cnt;
    logic         fill_sel;        // buffer being filled (0=A,1=B)
    logic [9:0]   wr_addr;
    logic [15:0]  wr_data;
    logic         wr_en;
    logic         primed;

    assign app_addr = {f_byte[28:4], 3'b000};
    assign app_cmd  = 3'b001;            // read
    assign app_burst_number = 6'd0;

    // line-RAM write port (app_clk)
    always_ff @(posedge app_clk) begin
        if (wr_en) begin
            if (fill_sel == 1'b0) lineA[wr_addr] <= wr_data;
            else                  lineB[wr_addr] <= wr_data;
        end
    end

    // sync line_req into app_clk
    always_ff @(posedge app_clk or negedge rst_n) begin
        if (!rst_n) begin
            line_req_a1 <= 1'b0;
            line_req_a2 <= 1'b0;
        end
        else begin
            line_req_a1 <= line_req_toggle;
            line_req_a2 <= line_req_a1;
        end
    end
    wire line_req_edge = (line_req_a2 != line_req_seen);

    always_ff @(posedge app_clk or negedge rst_n) begin
        if (!rst_n) begin
            d_st           <= D_IDLE;
            f_byte         <= FB_BASE;
            app_cmd_en     <= 1'b0;
            cap            <= 128'b0;
            pix_idx        <= 3'd0;
            beat_cnt       <= 10'd0;
            fill_sel       <= 1'b0;
            wr_en          <= 1'b0;
            wr_data        <= 16'b0;
            wr_addr        <= 10'd0;
            line_req_seen  <= 1'b0;
            line_ack_toggle<= 1'b0;
            primed         <= 1'b0;
        end
        else begin
            wr_en      <= 1'b0;
            unique case (d_st)
                D_IDLE: begin
                    app_cmd_en <= 1'b0;
                    if (init_calib_complete && (!primed || line_req_edge)) begin
                        // fill the next line into the buffer NOT currently shown
                        // (we alternate; the show side adopts it next line)
                        primed   <= 1'b1;
                        line_req_seen <= line_req_a2;
                        fill_sel <= ~fill_sel;
                        beat_cnt <= 10'd0;
                        pix_idx  <= 3'd0;
                        d_st     <= D_REQ;
                    end
                end
                D_REQ: begin
                    if (app_cmd_en && app_cmd_rdy) begin
                        app_cmd_en <= 1'b0;
                        d_st <= D_WAIT;
                    end
                    else begin
                        app_cmd_en <= init_calib_complete;
                    end
                end
                D_WAIT: begin
                    app_cmd_en <= 1'b0;
                    if (app_rdata_valid) begin
                        cap     <= app_rdata;
                        pix_idx <= 3'd0;
                        d_st    <= D_PUSH;
                    end
                end
                D_PUSH: begin
                    app_cmd_en <= 1'b0;
                    wr_en   <= 1'b1;
                    wr_data <= cap[pix_idx*16 +: 16];
                    wr_addr <= beat_cnt*BEAT_PIX + pix_idx;
                    if (pix_idx == 3'd7) begin
                        // beat complete
                        if (f_byte >= (FB_BASE + FB_BYTES - 16))
                            f_byte <= FB_BASE;
                        else
                            f_byte <= f_byte + 16;
                        if (beat_cnt == (LINE_BEATS - 1)) begin
                            // whole line ready
                            line_ack_toggle <= ~line_ack_toggle;
                            d_st <= D_IDLE;
                        end
                        else begin
                            beat_cnt <= beat_cnt + 10'd1;
                            d_st     <= D_REQ;
                        end
                    end
                    else begin
                        pix_idx <= pix_idx + 3'd1;
                    end
                end
                default: begin
                    app_cmd_en <= 1'b0;
                    d_st <= D_IDLE;
                end
            endcase
        end
    end

    // sync line_ack into pix_clk
    always_ff @(posedge pix_clk or posedge pix_rst) begin
        if (pix_rst) begin
            line_ack_p1 <= 1'b0;
            line_ack_p2 <= 1'b0;
        end
        else begin
            line_ack_p1 <= line_ack_toggle;
            line_ack_p2 <= line_ack_p1;
        end
    end

endmodule
