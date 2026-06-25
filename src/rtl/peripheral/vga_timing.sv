// 480x272 RGB565 panel timing generator (525x276 total), runs on lcd_dclk (~9 MHz).
// Ported from docs/ref/rgb_lcd_4.3inch_colorbar/src/vga_timing.v.
module vga_timing (
    input  logic        clk,        // pixel clock (lcd_dclk)
    input  logic        rst,        // reset, high active
    output logic        hs,         // horizontal sync
    output logic        vs,         // vertical sync
    output logic        de,         // data enable
    output logic [9:0]  active_x,   // active x position (0..H_ACTIVE-1)
    output logic [9:0]  active_y    // active y position (0..V_ACTIVE-1)
);

    localparam int H_ACTIVE = 480;
    localparam int H_FP     = 2;
    localparam int H_SYNC   = 41;
    localparam int H_BP     = 2;
    localparam int V_ACTIVE = 272;
    localparam int V_FP     = 2;
    localparam int V_SYNC   = 10;
    localparam int V_BP     = 2;
    localparam logic HS_POL = 1'b0;
    localparam logic VS_POL = 1'b0;

    localparam int H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
    localparam int V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

    logic       hs_reg, vs_reg;
    logic [11:0] h_cnt, v_cnt;
    logic       h_active, v_active;

    assign hs = hs_reg;
    assign vs = vs_reg;
    assign de = h_active & v_active;

    // horizontal counter
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            h_cnt <= 12'd0;
        else if (h_cnt == H_TOTAL - 1)
            h_cnt <= 12'd0;
        else
            h_cnt <= h_cnt + 12'd1;
    end

    // active_x
    always_ff @(posedge clk) begin
        if (h_cnt >= H_FP + H_SYNC + H_BP)
            active_x <= h_cnt - (H_FP[11:0] + H_SYNC[11:0] + H_BP[11:0]);
        else
            active_x <= active_x;
    end

    // active_y
    always_ff @(posedge clk) begin
        if (v_cnt >= V_FP + V_SYNC + V_BP)
            active_y <= v_cnt - (V_FP[11:0] + V_SYNC[11:0] + V_BP[11:0]);
        else
            active_y <= active_y;
    end

    // vertical counter (increments at horizontal sync time)
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            v_cnt <= 12'd0;
        else if (h_cnt == H_FP - 1) begin
            if (v_cnt == V_TOTAL - 1)
                v_cnt <= 12'd0;
            else
                v_cnt <= v_cnt + 12'd1;
        end
    end

    // HS
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            hs_reg <= 1'b0;
        else if (h_cnt == H_FP - 1)
            hs_reg <= HS_POL;
        else if (h_cnt == H_FP + H_SYNC - 1)
            hs_reg <= ~HS_POL;
    end

    // h_active
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            h_active <= 1'b0;
        else if (h_cnt == H_FP + H_SYNC + H_BP - 1)
            h_active <= 1'b1;
        else if (h_cnt == H_TOTAL - 1)
            h_active <= 1'b0;
    end

    // VS
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            vs_reg <= 1'b0;
        else if ((v_cnt == V_FP - 1) && (h_cnt == H_FP - 1))
            vs_reg <= HS_POL;
        else if ((v_cnt == V_FP + V_SYNC - 1) && (h_cnt == H_FP - 1))
            vs_reg <= ~vs_reg;
    end

    // v_active
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            v_active <= 1'b0;
        else if ((v_cnt == V_FP + V_SYNC + V_BP - 1) && (h_cnt == H_FP - 1))
            v_active <= 1'b1;
        else if ((v_cnt == V_TOTAL - 1) && (h_cnt == H_FP - 1))
            v_active <= 1'b0;
    end

endmodule