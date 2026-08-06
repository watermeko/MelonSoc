`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"
module uart_mmio #(
        parameter int unsigned CLK_FREQ          = soc_pkg::CLK_FREQ_HZ,
        parameter int unsigned UART_BAUD         = soc_pkg::UART_BAUD_RATE
    ) (
        input  logic clk,
        input  logic rst_n,
        input  logic rxd,
        output logic txd,
        wb_if.slave bus
    );
    import soc_pkg::*;
    assign bus.ack = bus.cyc && bus.stb;
    assign bus.stall = 1'b0;

    // ---------------- 寄存器映射 ----------------
    // DAT  @ IO_UART_DAT_ADDR   [7:0]  写：发送字节，读：接收字节
    // CTRL @ IO_UART_CTRL_ADDR:
    //   [0]  RX_VALID（只读）
    //   [1]  RX_OVERRUN（写 1 清除，只读）
    //   [2]  RX_FRAMEERR（写 1 清除，只读）
    //   [8]  TX_READY（只读）
    //   [9]  TX_BUSY（只读）

    logic sel_dat, sel_ctrl;
    always_comb begin
        sel_dat  = (align_word(bus.adr) == IO_UART_DAT_ADDR);
        sel_ctrl = (align_word(bus.adr) == IO_UART_CTRL_ADDR);
    end

    logic tx_valid;
    logic tx_ready;
    logic rx_ready;
    logic clear_overrun;
    logic clear_frame_err;
    logic [7:0] rx_data;
    logic rx_valid;
    logic rx_overrun;
    logic rx_frame_err;

    assign tx_valid = bus.cyc && bus.stb && bus.we && sel_dat && (|bus.sel);
    assign rx_ready = bus.cyc && bus.stb && !bus.we && sel_dat;

    assign clear_overrun   = bus.cyc && bus.stb && bus.we && sel_ctrl && bus.dat_w[UART_RX_OVERRUN_BIT];
    assign clear_frame_err = bus.cyc && bus.stb && bus.we && sel_ctrl && bus.dat_w[UART_RX_FRAMEERR_BIT];

    uart #(
             .CLK_FREQ(CLK_FREQ),
             .UART_BAUD(UART_BAUD)
         ) u_uart (
             .clk(clk),
             .rst_n(rst_n),
             .rxd(rxd),
             .tx_data(bus.dat_w[7:0]),
             .tx_valid(tx_valid),
             .tx_ready(tx_ready),
             .txd(txd),
             .rx_data(rx_data),
             .rx_valid(rx_valid),
             .rx_ready(rx_ready),
             .clear_overrun(clear_overrun),
             .clear_frame_err(clear_frame_err),
             .rx_overrun(rx_overrun),
             .rx_frame_err(rx_frame_err)
         );

    logic [31:0] data_rdata;
    logic [31:0] ctrl_rdata;

    always_comb begin
        data_rdata = {24'b0, rx_data};
        ctrl_rdata = 32'b0;
        ctrl_rdata[UART_RX_VALID_BIT]    = rx_valid;
        ctrl_rdata[UART_RX_OVERRUN_BIT]  = rx_overrun;
        ctrl_rdata[UART_RX_FRAMEERR_BIT] = rx_frame_err;
        ctrl_rdata[UART_TX_READY_BIT]    = tx_ready;
        ctrl_rdata[UART_TX_BUSY_BIT]     = ~tx_ready;
    end

    always_comb begin
        if (sel_dat) begin
            bus.dat_r = data_rdata;
        end
        else if (sel_ctrl) begin
            bus.dat_r = ctrl_rdata;
        end
        else begin
            bus.dat_r = 32'b0;
        end
    end
endmodule

module uart #(
        parameter CLK_FREQ = 27_000_000,
        parameter UART_BAUD = 115200
    )(
        input clk,
        input rst_n,
        input rxd,
        input [7:0] tx_data,
        input tx_valid,
        output tx_ready,
        output txd,
        output [7:0] rx_data,
        output rx_valid,
        input rx_ready,
        input clear_overrun,
        input clear_frame_err,
        output rx_overrun,
        output rx_frame_err
    );

    uart_tx #(
                .CLK_FREQ(CLK_FREQ),
                .UART_BAUD(UART_BAUD)
            ) u_uart_tx (
                .clk(clk),
                .rst_n(rst_n),
                .tx_data(tx_data),
                .tx_valid(tx_valid),
                .tx_ready(tx_ready),
                .txd(txd)
            );

    uart_rx_simple #(
                       .CLK_FREQ(CLK_FREQ),
                       .UART_BAUD(UART_BAUD)
                   ) u_uart_rx (
                       .clk(clk),
                       .rst_n(rst_n),
                       .rxd(rxd),
                       .rx_data(rx_data),
                       .rx_valid(rx_valid),
                       .rx_ready(rx_ready),
                       .clear_overrun(clear_overrun),
                       .clear_frame_err(clear_frame_err),
                       .rx_overrun(rx_overrun),
                       .rx_frame_err(rx_frame_err)
                   );

endmodule

module uart_tx #(
        parameter integer CLK_FREQ = 27_000_000,
        parameter integer UART_BAUD = 115200,
        parameter START_BIT = 1'b0,
        parameter STOP_BIT = 1'b1
    )(
        input clk,
        input rst_n,

        input [7:0] tx_data,
        input tx_valid,
        output logic tx_ready,
        output logic txd
    );

    localparam integer BIT_TICKS_RAW =
        (CLK_FREQ + (UART_BAUD / 2)) / UART_BAUD;
    localparam integer BIT_TICKS = (BIT_TICKS_RAW > 0) ? BIT_TICKS_RAW : 1;
    localparam integer BAUD_W = (BIT_TICKS > 1) ? $clog2(BIT_TICKS) : 1;
    localparam logic [BAUD_W-1:0] BIT_TICKS_M1 = BIT_TICKS - 1;

    logic [BAUD_W-1:0] baud_cnt;
    logic [3:0]        bit_index;
    logic [7:0]        tx_data_reg;

    // One start bit, eight data bits (LSB first), and one stop bit.  A request
    // is accepted only while ready; a stretched tx_valid can therefore not
    // restart the baud counter or overwrite a byte already in flight.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baud_cnt   <= '0;
            bit_index  <= 4'd0;
            tx_data_reg<= 8'd0;
            tx_ready   <= 1'b1;
            txd        <= STOP_BIT;
        end
        else if (tx_ready) begin
            baud_cnt  <= '0;
            bit_index <= 4'd0;
            txd       <= STOP_BIT;

            if (tx_valid) begin
                tx_data_reg <= tx_data;
                tx_ready    <= 1'b0;
                txd         <= START_BIT;
            end
        end
        else if (baud_cnt == BIT_TICKS_M1) begin
            baud_cnt <= '0;

            if (bit_index < 4'd8) begin
                txd       <= tx_data_reg[bit_index[2:0]];
                bit_index <= bit_index + 4'd1;
            end
            else if (bit_index == 4'd8) begin
                txd       <= STOP_BIT;
                bit_index <= 4'd9;
            end
            else begin
                txd       <= STOP_BIT;
                tx_ready  <= 1'b1;
                bit_index <= 4'd0;
            end
        end
        else begin
            baud_cnt <= baud_cnt + {{(BAUD_W-1){1'b0}}, 1'b1};
        end
    end

endmodule

module uart_rx_simple #(
        parameter integer CLK_FREQ = 27_000_000,
        parameter integer UART_BAUD = 115200
    )(
        input  logic       clk,
        input  logic       rst_n,
        input  logic       rxd,
        output logic [7:0] rx_data,
        output logic       rx_valid,
        input  logic       rx_ready,
        input  logic       clear_overrun,
        input  logic       clear_frame_err,
        output logic       rx_overrun,
        output logic       rx_frame_err
    );

    localparam int unsigned BAUD_TICKS =
               ((CLK_FREQ + (UART_BAUD/2)) / UART_BAUD) > 0 ? ((CLK_FREQ + (UART_BAUD/2)) / UART_BAUD) : 1;
    localparam int unsigned BAUD_TICKS_M1 = (BAUD_TICKS > 0) ? (BAUD_TICKS - 1) : 0;
    localparam int unsigned HALF_BAUD_TICKS = (BAUD_TICKS > 1) ? (BAUD_TICKS >> 1) : 1;

    typedef enum logic [1:0] {IDLE, START, DATA, STOP} state_t;
    state_t state;

    logic [$clog2(BAUD_TICKS+1)-1:0] baud_cnt;
    logic [2:0] bit_index;
    logic [7:0] rx_shift;

    logic rxd_meta, rxd_sync;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxd_meta <= 1'b1;
            rxd_sync <= 1'b1;
        end
        else begin
            rxd_meta <= rxd;
            rxd_sync <= rxd_meta;
        end
    end

    // 接收状态机
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            baud_cnt    <= '0;
            bit_index   <= 3'd0;
            rx_shift    <= 8'd0;
            rx_data     <= 8'd0;
            rx_valid    <= 1'b0;
            rx_overrun  <= 1'b0;
            rx_frame_err<= 1'b0;
        end
        else begin
            if (clear_overrun)
                rx_overrun   <= 1'b0;
            if (clear_frame_err)
                rx_frame_err <= 1'b0;

            if (rx_valid && rx_ready) begin
                rx_valid <= 1'b0;
            end

            case (state)
                IDLE: begin
                    baud_cnt  <= '0;
                    bit_index <= 3'd0;
                    if (!rxd_sync) begin
                        state <= START;
                    end
                end

                START: begin
                    if (baud_cnt >= HALF_BAUD_TICKS[$bits(baud_cnt)-1:0]) begin
                        baud_cnt <= '0;
                        if (!rxd_sync) begin
                            state <= DATA;
                        end
                        else begin
                            state <= IDLE;
                        end
                    end
                    else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                DATA: begin
                    if (baud_cnt >= BAUD_TICKS_M1[$bits(baud_cnt)-1:0]) begin
                        baud_cnt <= '0;
                        rx_shift[bit_index] <= rxd_sync;
                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            state <= STOP;
                        end
                        else begin
                            bit_index <= bit_index + 3'd1;
                        end
                    end
                    else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                STOP: begin
                    if (baud_cnt >= BAUD_TICKS_M1[$bits(baud_cnt)-1:0]) begin
                        baud_cnt <= '0;
                        if (rxd_sync) begin
                            if (rx_valid)
                                rx_overrun <= 1'b1;
                            rx_data  <= rx_shift;
                            rx_valid <= 1'b1;
                        end
                        else begin
                            rx_frame_err <= 1'b1;
                        end
                        state <= IDLE;
                    end
                    else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                default:
                    state <= IDLE;
            endcase
        end
    end

endmodule
