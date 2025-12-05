module SOC (
    input  clk,        // system clock
    input  rst_n,      // reset button
    output reg [5:0] leds, // system LEDs
    input  rxd,        // UART receive
    output txd         // UART transmit
);

// CPU 接口信号
wire [31:0] instr_addr, data_addr;
wire [31:0] instr_rdata, data_rdata;
wire instr_ren, data_ren;
wire [31:0] data_wdata;
wire [3:0] data_wmask;

// 内存输出
wire [31:0] PROGROM_rdata;
wire [31:0] DATARAM_rdata;

// 地址解码
wire [29:0] data_wordaddr = data_addr[31:2];
wire isDataIO = data_addr[22];       // 数据访问的 I/O 标志
wire isDataRAM = !isDataIO;
wire data_wen = |data_wmask;

// 内存模块
mem u_mem(
    .clk(clk),
    .instr_addr(instr_addr),
    .instr_rdata(PROGROM_rdata),
    .instr_ren(instr_ren),
    .data_addr(data_addr),
    .data_rdata(DATARAM_rdata),
    .data_ren(isDataRAM & data_ren),
    .data_wdata(data_wdata),
    .data_wmask({4{isDataRAM}} & data_wmask)
);

// CPU 模块
cpu u_cpu(
    .clk(clk),
    .rst_n(rst_n),
    .instr_addr(instr_addr),
    .instr_rdata(PROGROM_rdata),  // 指令直接从 PROGROM 读
    .instr_ren(instr_ren),
    .data_addr(data_addr),
    .data_rdata(data_rdata),      // 数据从 MUX 读
    .data_ren(data_ren),
    .data_wdata(data_wdata),
    .data_wmask(data_wmask)
);

// 数据读 MUX（RAM 或 I/O）
reg [31:0] io_data_reg;
assign data_rdata = isDataRAM ? DATARAM_rdata : io_data_reg;

localparam IO_LEDS_BIT = 0;
localparam IO_UART_DAT_BIT = 1;
localparam IO_UART_CTRL_BIT = 2;

// LED 控制
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        leds <= 6'b0;
    end else begin
        if (isDataIO && data_wen && data_wordaddr[IO_LEDS_BIT]) begin
            leds <= data_wdata[5:0];
        end
    end
end

// UART 模块
wire uart_valid = isDataIO && data_wen && data_wordaddr[IO_UART_DAT_BIT];
wire uart_ready;
wire uart_data_read_en = isDataIO && data_ren && data_wordaddr[IO_UART_DAT_BIT];
reg uart_data_read_en_q;
wire uart_data_read = uart_data_read_en && !uart_data_read_en_q;
wire uart_ctrl_write = isDataIO && data_wen && data_wordaddr[IO_UART_CTRL_BIT];
wire uart_clear_overrun = uart_ctrl_write && data_wdata[1];
wire uart_clear_frame_err = uart_ctrl_write && data_wdata[2];
wire [7:0] uart_rx_data;
wire uart_rx_valid;
wire uart_rx_overrun;
wire uart_rx_frame_err;

uart u_uart(
    .clk(clk),
    .rst_n(rst_n),
    .rxd(rxd),
    .tx_data(data_wdata[7:0]),
    .tx_valid(uart_valid),
    .tx_ready(uart_ready),
    .txd(txd),
    .rx_data(uart_rx_data),
    .rx_valid(uart_rx_valid),
    .rx_ready(uart_data_read),
    .clear_overrun(uart_clear_overrun),
    .clear_frame_err(uart_clear_frame_err),
    .rx_overrun(uart_rx_overrun),
    .rx_frame_err(uart_rx_frame_err)
);

wire [31:0] uart_data_rdata = {24'b0, uart_rx_data};
// IO_UART_CTRL 布局: [0]=RX valid, [1]=RX overrun, [2]=frame error, [8]=TX ready, [9]=TX busy
wire [31:0] uart_ctrl_rdata = {22'b0, !uart_ready, uart_ready, 5'b0, uart_rx_frame_err, uart_rx_overrun, uart_rx_valid};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        io_data_reg <= 32'b0;
    else if (isDataIO && data_ren) begin
        if (data_wordaddr[IO_UART_DAT_BIT])
            io_data_reg <= uart_data_rdata;
        else if (data_wordaddr[IO_UART_CTRL_BIT])
            io_data_reg <= uart_ctrl_rdata;
        else if (data_wordaddr[IO_LEDS_BIT])
            io_data_reg <= {26'b0, leds};
        else
            io_data_reg <= 32'b0;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        uart_data_read_en_q <= 1'b0;
    else
        uart_data_read_en_q <= uart_data_read_en;
end

`ifdef BENCH
    always @(posedge clk) begin
        if(uart_valid) begin
            $write("%c", data_wdata[7:0]);
            $fflush(32'h8000_0001);
        end
    end
`endif

endmodule
