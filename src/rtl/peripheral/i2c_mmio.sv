`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"

module i2c_mmio #(
        parameter int unsigned CLK_FREQ_HZ = soc_pkg::CLK_FREQ_HZ,
        parameter int unsigned I2C_DEFAULT_HZ = 100_000
    ) (
        input  logic clk,
        input  logic rst_n,
        wb_if.slave bus,

        inout  tri   sda,
        inout  tri   scl
    );
    import soc_pkg::*;
    assign bus.ack = bus.cyc && bus.stb;
    assign bus.stall = 1'b0;

    // ---------------- 寄存器映射 ----------------
    // TXRX   @ IO_I2C_TXRX_ADDR   [7:0]  写：发送字节（TX），读：接收字节（RX）
    // CMD    @ IO_I2C_CMD_ADDR:
    //   [0] START, [1] STOP, [2] WRITE, [3] READ, [4] ACK（用于 READ：1=ACK，0=NACK）
    // STATUS @ IO_I2C_STATUS_ADDR:
    //   [0] BUSY, [1] DONE（粘滞位）, [2] NACK（粘滞位：记录上一次 WRITE 的 NACK）
    // DIV    @ IO_I2C_DIV_ADDR    半周期分频计数（单位：clk 周期，>=1）

    logic sel_txrx, sel_cmd, sel_status, sel_div;
    always_comb begin
        sel_txrx   = (align_word(bus.adr) == IO_I2C_TXRX_ADDR);
        sel_cmd    = (align_word(bus.adr) == IO_I2C_CMD_ADDR);
        sel_status = (align_word(bus.adr) == IO_I2C_STATUS_ADDR);
        sel_div    = (align_word(bus.adr) == IO_I2C_DIV_ADDR);
    end

    // ---------------- MMIO 寄存器 ----------------
    logic [7:0]  tx_reg;
    logic [7:0]  rx_reg;
    logic [15:0] div_reg;

    logic cmd_ack;  // 仅保留 ACK 控制位

    logic busy;
    logic done;
    logic nack;

    localparam int unsigned DEFAULT_DIV =
               (CLK_FREQ_HZ / (2 * I2C_DEFAULT_HZ)) > 0 ? (CLK_FREQ_HZ / (2 * I2C_DEFAULT_HZ)) : 1;

    logic [15:0] div_eff;
    always_comb div_eff = |div_reg ? div_reg : 16'd1;

    // ---------------- I2C 状态机----------------
    typedef enum logic [3:0] {
                ST_IDLE  = 4'd0,
                ST_START = 4'd1,
                ST_BIT0  = 4'd2,
                ST_BIT1  = 4'd3,
                ST_ACK0  = 4'd4,
                ST_ACK1  = 4'd5,
                ST_STOP0 = 4'd6,
                ST_STOP1 = 4'd7,
                ST_DONE  = 4'd8
            } state_t;

    state_t state;
    logic [15:0] div_cnt;
    logic [7:0]  shift_reg;
    logic [2:0]  bit_idx;

    logic need_start, need_stop;
    logic op_write, op_read;

    logic tick;
    always_comb tick = (div_cnt == 16'd0);

    // 命令锁存与寄存器
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_reg <= 8'h00;
            div_reg <= DEFAULT_DIV[15:0];
        end
        else begin
            if (bus.cyc && bus.stb && bus.we && sel_txrx && (|bus.sel)) begin
                tx_reg <= bus.dat_w[7:0];
            end
            if (bus.cyc && bus.stb && bus.we && sel_div && (|bus.sel)) begin
                div_reg <= bus.dat_w[15:0];
            end
        end
    end

    // 内部开漏驱动（0=释放/高阻 Z，1=主动下拉为 0）。
    logic scl_drive_low;
    logic sda_drive_low;
    wire  sda_in = sda;

    assign scl = scl_drive_low ? 1'b0 : 1'bz;
    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    // Engine control + status
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            nack <= 1'b0;

            cmd_ack   <= 1'b0;

            need_start <= 1'b0;
            need_stop  <= 1'b0;
            op_write   <= 1'b0;
            op_read    <= 1'b0;

            state <= ST_IDLE;
            div_cnt <= 16'd0;
            shift_reg <= 8'h00;
            rx_reg <= 8'h00;
            bit_idx <= 3'd0;

            scl_drive_low <= 1'b0;
            sda_drive_low <= 1'b0;
        end
        else begin
            if (busy && (div_cnt != 16'd0))
                div_cnt <= div_cnt - 16'd1;

            // 空闲状态下接收并启动新命令。
            if (bus.cyc && bus.stb && bus.we && sel_cmd && (|bus.sel) && !busy) begin
                cmd_ack   <= bus.dat_w[4];

                need_start <= bus.dat_w[0];
                need_stop  <= bus.dat_w[1];
                op_write   <= bus.dat_w[2] & ~bus.dat_w[3];
                op_read    <= bus.dat_w[3];

                done <= 1'b0; // 新命令到来时清除粘滞标志
                nack <= 1'b0;

                busy <= 1'b1;
                state <= bus.dat_w[0] ? ST_START :
                      (bus.dat_w[2] | bus.dat_w[3]) ? ST_BIT0 :
                      bus.dat_w[1] ? ST_STOP0 : ST_DONE;

                shift_reg <= tx_reg;
                bit_idx <= 3'd7;

                scl_drive_low <= 1'b0;
                sda_drive_low <= 1'b0;
                div_cnt <= div_eff;
            end

            if (busy && tick) begin
                div_cnt <= (state == ST_DONE) ? 16'd0 : div_eff;
                unique case (state)
                    ST_START: begin
                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b1;
                        state <= ST_BIT0;
                    end
                    ST_BIT0: begin
                        scl_drive_low <= 1'b1;
                        sda_drive_low <= op_write ? ~shift_reg[bit_idx] : 1'b0;
                        state <= ST_BIT1;
                    end
                    ST_BIT1: begin
                        scl_drive_low <= 1'b0;
                        if (op_read) shift_reg[bit_idx] <= sda_in;
                        if (bit_idx == 3'd0) state <= ST_ACK0;
                        else begin
                            bit_idx <= bit_idx - 3'd1;
                            state <= ST_BIT0;
                        end
                    end
                    ST_ACK0: begin
                        scl_drive_low <= 1'b1;
                        sda_drive_low <= op_write ? 1'b0 : cmd_ack;
                        state <= ST_ACK1;
                    end
                    ST_ACK1: begin
                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b0;
                        if (op_write) nack <= sda_in;
                        if (op_read) rx_reg <= shift_reg;
                        state <= need_stop ? ST_STOP0 : ST_DONE;
                    end
                    ST_STOP0: begin
                        scl_drive_low <= 1'b1;
                        sda_drive_low <= 1'b1;
                        state <= ST_STOP1;
                    end
                    ST_STOP1: begin
                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b0;
                        state <= ST_DONE;
                    end
                    ST_DONE: begin
                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b0;
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end
                    default: state <= ST_DONE;
                endcase
            end
        end
    end

    // ---------------- MMIO 读回 ----------------
    always_comb begin
        case (1'b1)
            sel_txrx:   bus.dat_r = {24'b0, rx_reg};
            sel_status: bus.dat_r = {29'b0, nack, done, busy};
            sel_div:    bus.dat_r = {16'b0, div_reg};
            default:    bus.dat_r = 32'b0;
        endcase
    end
endmodule
