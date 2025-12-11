module mem(
    input clk,

    // 指令接口（只读）
    input [31:0] instr_addr,
    output reg [31:0] instr_rdata,
    input instr_ren,

    // 数据接口（读写）
    input [31:0] data_addr,
    output reg [31:0] data_rdata,
    input data_ren,
    input [31:0] data_wdata,
    input [3:0] data_wmask
);

// 指令存储器：64KB（16384 个 32 位字）
// 地址范围：0x00000 - 0x0FFFF
reg [31:0] PROGROM [0:16383];

// 数据存储器：64KB（16384 个 32 位字）
// 地址范围：0x10000 - 0x1FFFF
reg [31:0] DATARAM [0:16383];

// 地址映射：取 bit[15:2] 作为 14 位字地址
wire [13:0] instr_word_addr = instr_addr[15:2];
wire [13:0] data_word_addr = data_addr[15:2];

// 指令读取（同步读）
always @(posedge clk) begin
    if (instr_ren) begin
        instr_rdata <= PROGROM[instr_word_addr];
    end
end

// 数据读取和写入（同步读，同周期写）
always @(posedge clk) begin
    if (data_ren) begin
        data_rdata <= DATARAM[data_word_addr];
    end
    if (data_wmask[0]) DATARAM[data_word_addr][7:0]   <= data_wdata[7:0];
    if (data_wmask[1]) DATARAM[data_word_addr][15:8]  <= data_wdata[15:8];
    if (data_wmask[2]) DATARAM[data_word_addr][23:16] <= data_wdata[23:16];
    if (data_wmask[3]) DATARAM[data_word_addr][31:24] <= data_wdata[31:24];
end

// 初始化：从 hex 文件加载
initial begin
    `ifdef BENCH
    $readmemh("build/PROGROM.hex", PROGROM);
    $readmemh("build/DATARAM.hex", DATARAM);
    `else
    $readmemh("../build/PROGROM.hex", PROGROM);
    $readmemh("../build/DATARAM.hex", DATARAM);
    `endif 

    `ifdef BENCH
    $display("[MEM] Initialized PROGROM and DATARAM");
    $display("[MEM] PROGROM[0:3] = %h %h %h %h",
             PROGROM[0], PROGROM[1], PROGROM[2], PROGROM[3]);
    $display("[MEM] DATARAM[0:3] = %h %h %h %h",
             DATARAM[0], DATARAM[1], DATARAM[2], DATARAM[3]);
    `endif
end

endmodule
