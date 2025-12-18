`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"
module uart_mmio #(
  parameter int unsigned CLK_FREQ          = soc_pkg::CLK_FREQ_HZ,
  parameter int unsigned UART_BAUD         = soc_pkg::UART_BAUD,
  parameter int unsigned UART_RX_FIFO_DEPTH = soc_pkg::UART_RX_FIFO_DEPTH
) (
  input  logic clk,
  input  logic rst_n,
  input  logic rxd,
  output logic txd,
  simple_bus_if.slave bus
);
  import soc_pkg::*;

  logic sel_dat, sel_ctrl;
  always_comb begin
    sel_dat  = (align_word(bus.addr) == IO_UART_DAT_ADDR);
    sel_ctrl = (align_word(bus.addr) == IO_UART_CTRL_ADDR);
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

  assign tx_valid = bus.wen && sel_dat && (|bus.wstrb);
  assign rx_ready = bus.ren && sel_dat;

  assign clear_overrun   = bus.wen && sel_ctrl && bus.wdata[UART_RX_OVERRUN_BIT];
  assign clear_frame_err = bus.wen && sel_ctrl && bus.wdata[UART_RX_FRAMEERR_BIT];

  uart #(
    .CLK_FREQ(CLK_FREQ),
    .UART_BAUD(UART_BAUD),
    .UART_RX_FIFO_DEPTH(UART_RX_FIFO_DEPTH)
  ) u_uart (
    .clk(clk),
    .rst_n(rst_n),
    .rxd(rxd),
    .tx_data(bus.wdata[7:0]),
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
      bus.rdata = data_rdata;
    end else if (sel_ctrl) begin
      bus.rdata = ctrl_rdata;
    end else begin
      bus.rdata = 32'b0;
    end
  end
endmodule

module uart #(
    parameter CLK_FREQ = 27_000_000,
    parameter UART_BAUD = 115200,
    parameter UART_RX_FIFO_DEPTH = 16
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

uart_rx #(
    .CLK_FREQ(CLK_FREQ),
    .UART_BAUD(UART_BAUD),
    .RX_FIFO_DEPTH(UART_RX_FIFO_DEPTH)
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

module uart_tx(
    input clk,
    input rst_n,

    input [7:0] tx_data,
    input tx_valid,
    output reg tx_ready,
    output reg txd
);

parameter CLK_FREQ = 27_000_000;
parameter UART_BAUD = 115200;
parameter START_BIT = 1'b0;
parameter STOP_BIT = 1'b1;

/* verilator lint_off WIDTHTRUNC */
localparam [12:0] BAUD_CNT_MAX = CLK_FREQ / UART_BAUD;
/* verilator lint_on WIDTHTRUNC */

reg [12:0] baud_cnt;
reg [3:0] data_bit_count;
reg [7:0] tx_data_reg; //valid信号只维持一个周期，需要锁存数据

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        tx_ready <= 1'b1; // 空闲状态下，tx_ready为高电平
    else if (tx_valid) begin
        tx_ready <= 1'b0; // 发送使能时，设置为有效
        tx_data_reg <= tx_data; // 发送数据寄存器
    end
    else if ((baud_cnt == 13'd1)  && (data_bit_count == 4'd9))
        tx_ready <= 1'b1; // 发送完成后，清除使能信号
    else
        tx_ready <= tx_ready;
end

// 波特率计数器
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        baud_cnt <= 13'b0;
    else if (baud_cnt == (BAUD_CNT_MAX - 13'd1))
        baud_cnt <= 13'b0;           // 发送无效或计数到达最大值时清零
    else if (!tx_ready)
        baud_cnt <= baud_cnt + 1'b1; // 计数器加一
    else
        baud_cnt <= baud_cnt;
end


always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        data_bit_count <= 4'b0;
    else if (tx_ready && !tx_valid) begin // 当UART空闲时 (tx_ready为1，且没有新的发送请求tx_valid)
        data_bit_count <= 4'b0;         // 保持或复位 data_bit_count 为 0
    end
    else if (!tx_ready && (baud_cnt == 13'd1)) begin // 当UART忙于发送且到达每个比特的采样点时
        data_bit_count <= data_bit_count + 1'b1;  // 数据位计数器加一
    end
    // 在其他情况下，data_bit_count 保持其值 (例如，当 !tx_ready 但 baud_cnt != 1时)
end

// UART 数据发送逻辑
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        txd <= 1'b1; // 空闲状态为高电平
    else if (baud_cnt == 13'd1  ) begin
        case (data_bit_count)
            4'd0: txd <= START_BIT;             // 起始位
            4'd1: txd <= tx_data_reg[0];         // 数据最低位
            4'd2: txd <= tx_data_reg[1];
            4'd3: txd <= tx_data_reg[2];
            4'd4: txd <= tx_data_reg[3];
            4'd5: txd <= tx_data_reg[4];
            4'd6: txd <= tx_data_reg[5];
            4'd7: txd <= tx_data_reg[6];
            4'd8: txd <= tx_data_reg[7];          // 数据最高位
            4'd9: txd <= STOP_BIT;                // 停止位
            default: txd <= 1'b1;                // 默认状态
        endcase
    end
end



endmodule

module uart_rx #(
    parameter integer CLK_FREQ = 27_000_000,
    parameter integer UART_BAUD = 115200,
    parameter integer RX_FIFO_DEPTH = 16   // must be >=1, preferably power-of-two
)(
    input clk,
    input rst_n,
    input rxd,
    output [7:0] rx_data,
    output rx_valid,
    input rx_ready,
    input clear_overrun,
    input clear_frame_err,
    output reg rx_overrun,
    output reg rx_frame_err
);

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
localparam [15:0] BAUD_TICKS_SAFE_16 =
    ((CLK_FREQ + (UART_BAUD/2)) / UART_BAUD) > 0 ? ((CLK_FREQ + (UART_BAUD/2)) / UART_BAUD) : 16'd1;
localparam [15:0] BAUD_TICKS_SAFE_M1_16 =
    (BAUD_TICKS_SAFE_16 > 0) ? (BAUD_TICKS_SAFE_16 - 16'd1) : 16'd0;
localparam [15:0] HALF_BAUD_TICKS_16 =
    (BAUD_TICKS_SAFE_16 > 1) ? (BAUD_TICKS_SAFE_16 >> 1) : 16'd1;
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */

function integer clog2;
    input integer value;
    integer i;
    begin
        clog2 = 0;
        for (i = value - 1; i > 0; i = i >> 1)
            clog2 = clog2 + 1;
    end
endfunction

localparam [1:0] STATE_IDLE  = 2'd0;
localparam [1:0] STATE_START = 2'd1;
localparam [1:0] STATE_DATA  = 2'd2;
localparam [1:0] STATE_STOP  = 2'd3;
localparam integer RX_FIFO_ADDR_WIDTH = (RX_FIFO_DEPTH <= 1) ? 1 : clog2(RX_FIFO_DEPTH);

reg [1:0] state;
reg [15:0] baud_cnt;
reg [2:0] bit_index;
reg [7:0] rx_shift;
reg rxd_meta;
reg rxd_sync;
reg store_char;
reg frame_err_pulse;

reg [7:0] fifo_mem [0:RX_FIFO_DEPTH-1];
reg [RX_FIFO_ADDR_WIDTH-1:0] rd_ptr;
reg [RX_FIFO_ADDR_WIDTH-1:0] wr_ptr;
reg [RX_FIFO_ADDR_WIDTH:0] fifo_count;
reg [7:0] rx_data_reg;
reg rx_valid_reg;
reg pop_pending;

/* verilator lint_off WIDTHTRUNC */
localparam [RX_FIFO_ADDR_WIDTH:0] RX_FIFO_DEPTH_COUNT = RX_FIFO_DEPTH;
localparam [RX_FIFO_ADDR_WIDTH-1:0] RX_FIFO_LAST = RX_FIFO_DEPTH - 1;
/* verilator lint_on WIDTHTRUNC */
wire fifo_full  = (fifo_count == RX_FIFO_DEPTH_COUNT);
wire push_req   = store_char;
wire pop_req    = rx_ready && rx_valid_reg;
wire push_fifo  = push_req && !fifo_full;
wire fifo_overflow_attempt = push_req && fifo_full;
wire pop_fifo   = pop_pending;

function [RX_FIFO_ADDR_WIDTH-1:0] ptr_inc;
    input [RX_FIFO_ADDR_WIDTH-1:0] ptr;
    begin
        if (ptr == RX_FIFO_LAST)
            ptr_inc = {RX_FIFO_ADDR_WIDTH{1'b0}};
        else
            ptr_inc = ptr + 1'b1;
    end
endfunction

wire [RX_FIFO_ADDR_WIDTH-1:0] rd_ptr_next = ptr_inc(rd_ptr);
wire [RX_FIFO_ADDR_WIDTH-1:0] wr_ptr_next = ptr_inc(wr_ptr);

wire [RX_FIFO_ADDR_WIDTH:0] fifo_count_inc = fifo_count + 1'b1;
wire [RX_FIFO_ADDR_WIDTH:0] fifo_count_dec = fifo_count - 1'b1;
reg  [RX_FIFO_ADDR_WIDTH:0] fifo_count_next;

assign rx_data = rx_data_reg;
assign rx_valid = rx_valid_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        pop_pending <= 1'b0;
    else if (pop_pending)
        pop_pending <= 1'b0;
    else if (pop_req)
        pop_pending <= 1'b1;
end

always @(*) begin
    case ({push_fifo, pop_fifo})
        2'b10: fifo_count_next = fifo_count_inc;
        2'b01: fifo_count_next = fifo_count_dec;
        default: fifo_count_next = fifo_count;
    endcase
end

// Synchronize RXD to clk domain
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rxd_meta <= 1'b1;
        rxd_sync <= 1'b1;
    end else begin
        rxd_meta <= rxd;
        rxd_sync <= rxd_meta;
    end
end

// UART RX state machine
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= STATE_IDLE;
        baud_cnt <= 16'd0;
        bit_index <= 3'd0;
        rx_shift <= 8'd0;
        store_char <= 1'b0;
        frame_err_pulse <= 1'b0;
    end else begin
        store_char <= 1'b0;
        frame_err_pulse <= 1'b0;

        case (state)
            STATE_IDLE: begin
                baud_cnt <= 16'd0;
                bit_index <= 3'd0;
                if (!rxd_sync)
                    state <= STATE_START;
            end

            STATE_START: begin
	                if (baud_cnt >= HALF_BAUD_TICKS_16) begin
                    baud_cnt <= 16'd0;
                    if (!rxd_sync)
                        state <= STATE_DATA;
                    else
                        state <= STATE_IDLE;
                end else
                    baud_cnt <= baud_cnt + 16'd1;
            end

            STATE_DATA: begin
	                if (baud_cnt >= BAUD_TICKS_SAFE_M1_16) begin
                    baud_cnt <= 16'd0;
	                    rx_shift[bit_index] <= rxd_sync;
	                    if (bit_index == 3'd7) begin
	                        bit_index <= 3'd0;
	                        state <= STATE_STOP;
	                    end else
	                        bit_index <= bit_index + 3'd1;
                end else
                    baud_cnt <= baud_cnt + 16'd1;
            end

            STATE_STOP: begin
	                if (baud_cnt >= BAUD_TICKS_SAFE_M1_16) begin
                    baud_cnt <= 16'd0;
                    if (rxd_sync) begin
                        store_char <= 1'b1;
                    end else begin
                        frame_err_pulse <= 1'b1;
                    end
                    state <= STATE_IDLE;
                end else
                    baud_cnt <= baud_cnt + 16'd1;
            end

            default: begin
                state <= STATE_IDLE;
            end
        endcase
    end
end

// RX FIFO and output register
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_ptr <= {RX_FIFO_ADDR_WIDTH{1'b0}};
        wr_ptr <= {RX_FIFO_ADDR_WIDTH{1'b0}};
        fifo_count <= {RX_FIFO_ADDR_WIDTH+1{1'b0}};
        rx_data_reg <= 8'd0;
        rx_valid_reg <= 1'b0;
        rx_overrun <= 1'b0;
        rx_frame_err <= 1'b0;
    end else begin
        if (clear_overrun)
            rx_overrun <= 1'b0;
        else if (fifo_overflow_attempt)
            rx_overrun <= 1'b1;

        if (clear_frame_err)
            rx_frame_err <= 1'b0;
        else if (frame_err_pulse)
            rx_frame_err <= 1'b1;

        if (push_fifo) begin
            fifo_mem[wr_ptr] <= rx_shift;
            wr_ptr <= wr_ptr_next;
        end

        if (pop_fifo)
            rd_ptr <= rd_ptr_next;

        fifo_count <= fifo_count_next;
        rx_valid_reg <= (fifo_count_next != 0);

        if (pop_fifo) begin
            if (fifo_count > 1) begin
                rx_data_reg <= fifo_mem[rd_ptr_next];
            end else if ((fifo_count == 1) && push_fifo) begin
                rx_data_reg <= rx_shift;
            end else begin
                rx_data_reg <= 8'd0;
            end
        end else if (!rx_valid_reg && push_fifo && !pop_fifo) begin
            rx_data_reg <= rx_shift;
        end
    end
end

endmodule
