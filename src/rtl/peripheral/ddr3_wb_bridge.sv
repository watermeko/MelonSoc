`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"

module ddr3_wb_bridge #(
        parameter int unsigned APP_ADDR_W = 28
    ) (
        input  logic clk,
        input  logic app_clk,
        input  logic rst_n,
        wb_if.slave bus,

        output logic [APP_ADDR_W-1:0] app_addr,
        output logic                 app_cmd_en,
        output logic [2:0]           app_cmd,
        input  logic                 app_cmd_rdy,

        output logic                 app_wren,
        output logic                 app_data_end,
        output logic [127:0]         app_data,
        input  logic                 app_data_rdy,

        input  logic                 app_rdata_valid,
        input  logic                 app_rdata_end,
        input  logic [127:0]         app_rdata,

        input  logic                 init_calib_complete,
        output logic [5:0]           app_burst_number
    );
    import soc_pkg::*;

    typedef enum logic [2:0] {
        S_IDLE,
        S_READ_CMD,
        S_READ_WAIT,
        S_WRITE_CMD,
        S_ACK
    } state_t;

    state_t app_state;
    logic bus_busy;
    logic req_toggle;
    logic req_toggle_app_meta;
    logic req_toggle_app_sync;
    logic req_toggle_app_seen;
    logic rsp_toggle;
    logic rsp_toggle_bus_meta;
    logic rsp_toggle_bus_sync;
    logic rsp_toggle_bus_seen;
    logic rsp_ack_pending;

    logic req_we;
    logic [31:0] req_addr;
    logic [31:0] req_dat_w;
    logic [3:0] req_sel;
    logic [31:0] rsp_dat_r;
    logic [127:0] line;

    wire [1:0] word_sel = req_addr[3:2];
    wire [APP_ADDR_W-1:0] line_app_addr = {req_addr[APP_ADDR_W:4], 3'b000};

    function automatic logic [127:0] merge_word(
        input logic [127:0] old_line,
        input logic [1:0] word_index,
        input logic [31:0] word_data,
        input logic [3:0] byte_sel
    );
        logic [127:0] merged;
        int base;
        begin
            merged = old_line;
            base = int'(word_index) * 32;
            for (int i = 0; i < 4; ++i) begin
                if (byte_sel[i]) begin
                    merged[base + i*8 +: 8] = word_data[i*8 +: 8];
                end
            end
            return merged;
        end
    endfunction

    always_comb begin
        bus.stall = bus_busy;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_busy <= 1'b0;
            req_toggle <= 1'b0;
            rsp_toggle_bus_meta <= 1'b0;
            rsp_toggle_bus_sync <= 1'b0;
            rsp_toggle_bus_seen <= 1'b0;
            rsp_ack_pending <= 1'b0;
            req_we <= 1'b0;
            req_addr <= 32'b0;
            req_dat_w <= 32'b0;
            req_sel <= 4'b0;
            bus.dat_r <= 32'b0;
            bus.ack <= 1'b0;
        end
        else begin
            bus.ack <= 1'b0;
            rsp_toggle_bus_meta <= rsp_toggle;
            rsp_toggle_bus_sync <= rsp_toggle_bus_meta;

            if (rsp_ack_pending) begin
                bus.ack <= 1'b1;
                bus_busy <= 1'b0;
                rsp_ack_pending <= 1'b0;
            end
            else if (bus_busy && (rsp_toggle_bus_sync != rsp_toggle_bus_seen)) begin
                rsp_toggle_bus_seen <= rsp_toggle_bus_sync;
                bus.dat_r <= rsp_dat_r;
                rsp_ack_pending <= 1'b1;
            end
            else if (!bus_busy && bus.cyc && bus.stb && !bus.ack) begin
                req_we <= bus.we;
                req_addr <= bus.adr;
                req_dat_w <= bus.dat_w;
                req_sel <= bus.sel;
                req_toggle <= ~req_toggle;
                bus_busy <= 1'b1;
            end
        end
    end

    always_ff @(posedge app_clk or negedge rst_n) begin
        if (!rst_n) begin
            app_state <= S_IDLE;
            req_toggle_app_meta <= 1'b0;
            req_toggle_app_sync <= 1'b0;
            req_toggle_app_seen <= 1'b0;
            rsp_toggle <= 1'b0;
            rsp_dat_r <= 32'b0;
            line <= 128'b0;
            app_addr <= '0;
            app_cmd_en <= 1'b0;
            app_cmd <= 3'd0;
            app_wren <= 1'b0;
            app_data_end <= 1'b0;
            app_data <= 128'b0;
            app_burst_number <= 6'd0;
        end
        else begin
            req_toggle_app_meta <= req_toggle;
            req_toggle_app_sync <= req_toggle_app_meta;
            app_cmd_en <= 1'b0;
            app_wren <= 1'b0;
            app_data_end <= 1'b0;
            app_burst_number <= 6'd0;

            unique case (app_state)
                S_IDLE: begin
                    if ((req_toggle_app_sync != req_toggle_app_seen) && init_calib_complete) begin
                        req_toggle_app_seen <= req_toggle_app_sync;
                        app_addr <= line_app_addr;
                        app_cmd <= 3'd1;
                        app_state <= S_READ_CMD;
                    end
                end
                S_READ_CMD: begin
                    app_addr <= line_app_addr;
                    app_cmd <= 3'd1;
                    if (app_cmd_rdy) begin
                        app_cmd_en <= 1'b1;
                        app_state <= S_READ_WAIT;
                    end
                end
                S_READ_WAIT: begin
                    if (app_rdata_valid) begin
                        line <= app_rdata;
                        if (req_we) begin
                            app_data <= merge_word(app_rdata, word_sel, req_dat_w, req_sel);
                            app_state <= S_WRITE_CMD;
                        end
                        else begin
                            unique case (word_sel)
                                2'd0: rsp_dat_r <= app_rdata[31:0];
                                2'd1: rsp_dat_r <= app_rdata[63:32];
                                2'd2: rsp_dat_r <= app_rdata[95:64];
                                default: rsp_dat_r <= app_rdata[127:96];
                            endcase
                            app_state <= S_ACK;
                        end
                    end
                end
                S_WRITE_CMD: begin
                    app_addr <= line_app_addr;
                    app_cmd <= 3'd0;
                    app_data <= merge_word(line, word_sel, req_dat_w, req_sel);
                    if (app_cmd_rdy && app_data_rdy) begin
                        app_cmd_en <= 1'b1;
                        app_wren <= 1'b1;
                        app_data_end <= 1'b1;
                        app_state <= S_ACK;
                    end
                end
                S_ACK: begin
                    rsp_toggle <= ~rsp_toggle;
                    app_state <= S_IDLE;
                end
                default: app_state <= S_IDLE;
            endcase
        end
    end
endmodule
