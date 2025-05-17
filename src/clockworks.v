module clockworks(
    input clk,
    output slow_clk
);

parameter SLOW = 0;
`ifdef FREQ_DIV
localparam FREQ_DIV = `FREQ_DIV;
`else
localparam FREQ_DIV = SLOW;
`endif 


reg [FREQ_DIV:0] slow_clk_count = 0;
always @(posedge clk) begin
    slow_clk_count <= slow_clk_count + 1;
end

assign slow_clk = slow_clk_count[FREQ_DIV];
endmodule