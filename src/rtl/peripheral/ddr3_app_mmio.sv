`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"

module ddr3_app_mmio #(
        parameter int unsigned APP_ADDR_W = 28
    ) (
        input  logic clk,
        input  logic app_clk,
        input  logic rst_n,
        simple_bus_if.slave bus,

        // DDR3 APP 接口（对接 Gowin DDR3_Memory_Interface_Top）
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

    // ---------------- 寄存器映射 ----------------
    // 见 soc_pkg.sv：IO_DDR_*_ADDR

    logic sel_ctrl, sel_status, sel_addr, sel_burst;
    logic sel_w0, sel_w1, sel_w2, sel_w3;
    logic sel_r0, sel_r1, sel_r2, sel_r3;

    always_comb begin
        sel_ctrl   = (align_word(bus.addr) == IO_DDR_CTRL_ADDR);
        sel_status = (align_word(bus.addr) == IO_DDR_STATUS_ADDR);
        sel_addr   = (align_word(bus.addr) == IO_DDR_ADDR_ADDR);
        sel_burst  = (align_word(bus.addr) == IO_DDR_BURST_ADDR);

        sel_w0     = (align_word(bus.addr) == IO_DDR_WDATA0_ADDR);
        sel_w1     = (align_word(bus.addr) == IO_DDR_WDATA1_ADDR);
        sel_w2     = (align_word(bus.addr) == IO_DDR_WDATA2_ADDR);
        sel_w3     = (align_word(bus.addr) == IO_DDR_WDATA3_ADDR);

        sel_r0     = (align_word(bus.addr) == IO_DDR_RDATA0_ADDR);
        sel_r1     = (align_word(bus.addr) == IO_DDR_RDATA1_ADDR);
        sel_r2     = (align_word(bus.addr) == IO_DDR_RDATA2_ADDR);
        sel_r3     = (align_word(bus.addr) == IO_DDR_RDATA3_ADDR);
    end

    // ---------------- MMIO（clk 域）寄存器 ----------------
    logic [APP_ADDR_W-1:0] addr_reg;
    logic [5:0]            burst_reg;
    logic [127:0]          wdata_reg;
    logic [127:0]          rdata_reg;

    logic op_write;
    logic busy;
    logic done;
    logic err;

    // CTRL 写入的边沿触发（clk 域）
    logic start_pulse;
    logic clr_done_pulse;
    logic clr_err_pulse;

    always_comb begin
        start_pulse    = bus.wen && sel_ctrl && (|bus.wstrb) && bus.wdata[0];
        clr_done_pulse = bus.wen && sel_ctrl && (|bus.wstrb) && bus.wdata[2];
        clr_err_pulse  = bus.wen && sel_ctrl && (|bus.wstrb) && bus.wdata[3];
    end

    // ---------------- CDC：请求/响应 Toggle ----------------
    logic req_toggle;
    logic resp_toggle_app;

    logic resp_toggle_meta, resp_toggle_sync, resp_toggle_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_toggle_meta <= 1'b0;
            resp_toggle_sync <= 1'b0;
            resp_toggle_q <= 1'b0;
        end
        else begin
            resp_toggle_meta <= resp_toggle_app;
            resp_toggle_sync <= resp_toggle_meta;
            resp_toggle_q <= resp_toggle_sync;
        end
    end

    wire resp_edge = (resp_toggle_sync ^ resp_toggle_q);

    // ---------------- 配置寄存器写入（clk 域） ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr_reg  <= '0;
            burst_reg <= 6'd0;
            wdata_reg <= '0;
        end
        else begin
            if (bus.wen && sel_addr && (|bus.wstrb)) begin
                addr_reg <= bus.wdata[APP_ADDR_W-1:0];
            end
            if (bus.wen && sel_burst && (|bus.wstrb)) begin
                burst_reg <= bus.wdata[5:0];
            end
            if (bus.wen && sel_w0 && (|bus.wstrb)) wdata_reg[31:0]   <= bus.wdata;
            if (bus.wen && sel_w1 && (|bus.wstrb)) wdata_reg[63:32]  <= bus.wdata;
            if (bus.wen && sel_w2 && (|bus.wstrb)) wdata_reg[95:64]  <= bus.wdata;
            if (bus.wen && sel_w3 && (|bus.wstrb)) wdata_reg[127:96] <= bus.wdata;
        end
    end

    // ---------------- app 域回传数据同步到 clk 域 ----------------
    logic [127:0] resp_rdata_app;
    logic         resp_err_app;

    logic [127:0] resp_rdata_meta, resp_rdata_sync;
    logic         resp_err_meta, resp_err_sync;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_rdata_meta <= '0;
            resp_rdata_sync <= '0;
            resp_err_meta <= 1'b0;
            resp_err_sync <= 1'b0;
        end
        else begin
            resp_rdata_meta <= resp_rdata_app;
            resp_rdata_sync <= resp_rdata_meta;
            resp_err_meta <= resp_err_app;
            resp_err_sync <= resp_err_meta;
        end
    end

    // ---------------- app 域状态同步到 clk 域（用于 probe） ----------------
    logic init_meta, init_sync;
    logic cmd_rdy_meta, cmd_rdy_sync;
    logic wdata_rdy_meta, wdata_rdy_sync;
    logic rd_valid_meta, rd_valid_sync;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_meta <= 1'b0; init_sync <= 1'b0;
            cmd_rdy_meta <= 1'b0; cmd_rdy_sync <= 1'b0;
            wdata_rdy_meta <= 1'b0; wdata_rdy_sync <= 1'b0;
            rd_valid_meta <= 1'b0; rd_valid_sync <= 1'b0;
        end
        else begin
            init_meta <= init_calib_complete;
            init_sync <= init_meta;

            cmd_rdy_meta <= app_cmd_rdy;
            cmd_rdy_sync <= cmd_rdy_meta;

            wdata_rdy_meta <= app_data_rdy;
            wdata_rdy_sync <= wdata_rdy_meta;

            rd_valid_meta <= app_rdata_valid;
            rd_valid_sync <= rd_valid_meta;
        end
    end

    // ---------------- MMIO 控制/状态（clk 域） ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_write <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            err <= 1'b0;
            rdata_reg <= '0;
            req_toggle <= 1'b0;
        end
        else begin
            if (clr_done_pulse) done <= 1'b0;
            if (clr_err_pulse)  err  <= 1'b0;

            if (start_pulse && !busy) begin
                op_write <= bus.wdata[1];
                done <= 1'b0;
                err <= 1'b0;

                if (burst_reg != 6'd0) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    err <= 1'b1;
                end
                else begin
                    busy <= 1'b1;
                    req_toggle <= ~req_toggle;
                end
            end

            if (resp_edge) begin
                rdata_reg <= resp_rdata_sync;
                busy <= 1'b0;
                done <= 1'b1;
                if (resp_err_sync)
                    err <= 1'b1;
            end
        end
    end

    // ---------------- APP 接口（app_clk 域）命令引擎 ----------------
    // 说明：
    // - ref/src/tester.v 使用 DDR3 IP 的 clk_out（clk_x1）驱动 app_*。
    // - 为避免跨域丢脉冲，这里在 app_clk 域完成一次读/写，并用 toggle 回传完成事件。

    // 请求 toggle 同步到 app_clk
    logic req_toggle_meta, req_toggle_sync, req_toggle_q;
    always_ff @(posedge app_clk or negedge rst_n) begin
        if (!rst_n) begin
            req_toggle_meta <= 1'b0;
            req_toggle_sync <= 1'b0;
            req_toggle_q <= 1'b0;
        end
        else begin
            req_toggle_meta <= req_toggle;
            req_toggle_sync <= req_toggle_meta;
            req_toggle_q <= req_toggle_sync;
        end
    end
    wire req_edge = (req_toggle_sync ^ req_toggle_q);

    // 配置寄存器同步到 app_clk（多比特两级同步；在 busy 期间保持稳定）
    logic [APP_ADDR_W-1:0] addr_meta, addr_sync;
    logic [5:0]            burst_meta, burst_sync;
    logic [127:0]          wdata_meta, wdata_sync;
    logic                 opw_meta, opw_sync;

    always_ff @(posedge app_clk or negedge rst_n) begin
        if (!rst_n) begin
            addr_meta <= '0; addr_sync <= '0;
            burst_meta <= '0; burst_sync <= '0;
            wdata_meta <= '0; wdata_sync <= '0;
            opw_meta <= 1'b0; opw_sync <= 1'b0;
        end
        else begin
            addr_meta <= addr_reg;
            addr_sync <= addr_meta;
            burst_meta <= burst_reg;
            burst_sync <= burst_meta;
            wdata_meta <= wdata_reg;
            wdata_sync <= wdata_meta;
            opw_meta <= op_write;
            opw_sync <= opw_meta;
        end
    end

    typedef enum logic [1:0] {
        A_IDLE    = 2'd0,
        A_ISSUE   = 2'd1,
        A_WAIT_RD = 2'd2,
        A_DONE    = 2'd3
    } astate_t;

    astate_t astate;
    logic [31:0] timeout_cnt;

    always_ff @(posedge app_clk or negedge rst_n) begin
        if (!rst_n) begin
            app_cmd_en   <= 1'b0;
            app_wren     <= 1'b0;
            app_data_end <= 1'b0;
            app_addr     <= '0;
            app_cmd      <= 3'd0;
            app_data     <= '0;
            app_burst_number <= 6'd0;

            resp_toggle_app <= 1'b0;
            resp_rdata_app  <= '0;
            resp_err_app    <= 1'b0;

            timeout_cnt <= 32'd0;
            astate <= A_IDLE;
        end
        else begin
            app_cmd_en   <= 1'b0;
            app_wren     <= 1'b0;
            app_data_end <= 1'b0;

            // 默认保持输出为当前同步过来的配置
            app_addr         <= addr_sync;
            app_burst_number <= burst_sync;
            app_data         <= wdata_sync;
            app_cmd          <= opw_sync ? 3'd0 : 3'd1; // WR_CMD=0, RD_CMD=1

            if (req_edge) begin
                resp_err_app <= 1'b0;
                timeout_cnt <= 32'd0;
                astate <= A_ISSUE;
            end

            if (astate != A_IDLE) begin
                timeout_cnt <= timeout_cnt + 32'd1;
                // 超时：避免 busy 永久卡死（app_clk 频率未知，给较大阈值）
                if (timeout_cnt == 32'd200_000_000) begin
                    resp_err_app <= 1'b1;
                    astate <= A_DONE;
                end
            end

            unique case (astate)
                A_IDLE: begin end
                A_ISSUE: begin
                    if (!init_calib_complete) begin
                        // wait DDR init
                    end
                    else if (opw_sync) begin
                        if (app_cmd_rdy && app_data_rdy) begin
                            app_cmd_en   <= 1'b1;
                            app_wren     <= 1'b1;
                            app_data_end <= 1'b1;
                            astate <= A_DONE;
                        end
                    end
                    else begin
                        if (app_cmd_rdy) begin
                            app_cmd_en <= 1'b1;
                            astate <= A_WAIT_RD;
                        end
                    end
                end
                A_WAIT_RD: begin
                    if (app_rdata_valid) begin
                        resp_rdata_app <= app_rdata;
                        astate <= A_DONE;
                    end
                end
                A_DONE: begin
                    resp_toggle_app <= ~resp_toggle_app;
                    astate <= A_IDLE;
                end
                default: astate <= A_IDLE;
            endcase
        end
    end

    // ---------------- MMIO 读回 ----------------
    logic [31:0] status_rdata;
    always_comb begin
        status_rdata = 32'b0;
        status_rdata[0] = 1'b1; // PRESENT
        status_rdata[1] = init_sync;
        status_rdata[2] = busy;
        status_rdata[3] = done;
        status_rdata[4] = err;
        status_rdata[5] = cmd_rdy_sync;
        status_rdata[6] = wdata_rdy_sync;
        status_rdata[7] = rd_valid_sync;
    end

    always_comb begin
        if (sel_ctrl) begin
            // START/CLR_* 为脉冲；读回只返回 WRITE 位与 0
            bus.rdata = {30'b0, op_write, 1'b0};
        end
        else if (sel_status) begin
            bus.rdata = status_rdata;
        end
        else if (sel_addr) begin
            bus.rdata = {{(32-APP_ADDR_W){1'b0}}, addr_reg};
        end
        else if (sel_burst) begin
            bus.rdata = {26'b0, burst_reg};
        end
        else if (sel_w0) begin
            bus.rdata = wdata_reg[31:0];
        end
        else if (sel_w1) begin
            bus.rdata = wdata_reg[63:32];
        end
        else if (sel_w2) begin
            bus.rdata = wdata_reg[95:64];
        end
        else if (sel_w3) begin
            bus.rdata = wdata_reg[127:96];
        end
        else if (sel_r0) begin
            bus.rdata = rdata_reg[31:0];
        end
        else if (sel_r1) begin
            bus.rdata = rdata_reg[63:32];
        end
        else if (sel_r2) begin
            bus.rdata = rdata_reg[95:64];
        end
        else if (sel_r3) begin
            bus.rdata = rdata_reg[127:96];
        end
        else begin
            bus.rdata = 32'b0;
        end
    end
endmodule
