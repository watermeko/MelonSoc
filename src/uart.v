module uart(
    input clk,
    input rst_n,

    input [7:0] tx_data,
    input tx_valid,
    output tx_ready,
    output txd
);

uart_tx #(
    .CLK_FREQ(27_000_000),
    .UART_BAUD(115200)
) u_uart_tx (
    .clk(clk),
    .rst_n(rst_n),
    .tx_data(tx_data),
    .tx_valid(tx_valid),
    .tx_ready(tx_ready),
    .txd(txd)
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

localparam BAUD_CNT_MAX = CLK_FREQ / UART_BAUD;

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
    else if ( (baud_cnt == BAUD_CNT_MAX - 1'd1))
        baud_cnt <= 13'b0;           // 发送无效或计数到达最大值时清零
    else if (!tx_ready)
        baud_cnt <= baud_cnt + 1'b1; // 计数器加一
    else
        baud_cnt <= baud_cnt;
end


always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        data_bit_count <= 4'b0;
    else  if(baud_cnt == 13'd1) begin
        if (!tx_ready)
            data_bit_count <= data_bit_count + 1'b1;  //每波特率计数器的第一个时钟周期，数据位加一
        else if(data_bit_count == 4'd9)
            data_bit_count <= 4'd0;                    //发送完时，数据位清零
    end
    else
        data_bit_count <= data_bit_count;
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
