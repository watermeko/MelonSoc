module mem(
    input clk,
    input [31:0] mem_addr,
    output reg [31:0] mem_rdata,
    input mem_ren,
    input [31:0] mem_wdata,
    input [3:0] mem_wmask
);

reg [31:0] MEM [0:255];

wire [29:0] word_addr = mem_addr[31:2];

always @(posedge clk) begin
    if(mem_ren) begin
        mem_rdata <= MEM[mem_addr[31:2]];
    end
    if(mem_wmask[0]) MEM[word_addr][7:0] <= mem_wdata[7:0];
    if(mem_wmask[1]) MEM[word_addr][15:8] <= mem_wdata[15:8];
    if(mem_wmask[2]) MEM[word_addr][23:16] <= mem_wdata[23:16];
    if(mem_wmask[3]) MEM[word_addr][31:24] <= mem_wdata[31:24];
end

initial begin
    $readmemh("build/program.hex", MEM);

    MEM[100] = {8'h4, 8'h3, 8'h2, 8'h1};
    MEM[101] = {8'h8, 8'h7, 8'h6, 8'h5};
    MEM[102] = {8'hc, 8'hb, 8'ha, 8'h9};
    MEM[103] = {8'hff, 8'hf, 8'he, 8'hd};
end

endmodule