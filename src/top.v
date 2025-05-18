module SOC (
    input  clk,        // system clock 
    input  rst_n,      // reset button
    output reg [5:0] leds, // system LEDs
    input  rxd,        // UART receive
    output txd         // UART transmit
);

wire [31:0] mem_addr;
wire [31:0] mem_rdata;
wire mem_ren;
wire [31:0] mem_wdata;
wire [3:0]  mem_wmask;

wire [31:0] RAM_rdata;
wire [29:0] mem_wordaddr = mem_addr[31:2];
wire isIO = mem_addr[22];
wire isRAM = !isIO;
wire mem_wen = |mem_wmask;

mem u_mem(
  .clk(clk),
  .mem_addr(mem_addr),
  .mem_rdata(RAM_rdata),
  .mem_ren(isRAM&mem_ren),
  .mem_wdata(mem_wdata),
  .mem_wmask({4{isRAM}}&mem_wmask)
);

cpu u_cpu(
  .clk(clk),
  .rst_n(rst_n),		 
  .mem_addr(mem_addr),
  .mem_rdata(mem_rdata),
  .mem_ren(mem_ren),
  .mem_wdata(mem_wdata),
  .mem_wmask(mem_wmask)		 
);

assign mem_rdata = isRAM ? RAM_rdata :
                  IO_data ;

localparam IO_LEDS_BIT = 0;
localparam IO_UART_DAT_BIT = 1;
localparam IO_UART_CTRL_BIT = 2;



always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
      leds <= 6'b0;
  end else begin
      if (isIO && mem_wen && mem_wordaddr[IO_LEDS_BIT]) begin
        leds <= mem_wdata[5:0];
      end
  end
end

wire uart_valid = isIO && mem_wen && mem_wordaddr[IO_UART_DAT_BIT];
wire uart_ready;
uart u_uart(
  .clk(clk),
  .rst_n(rst_n),
  .tx_data(mem_wdata[7:0]),
  .tx_valid(uart_valid),
  .tx_ready(uart_ready),
  .txd(txd)
);

wire [31:0] IO_data = mem_wordaddr[IO_UART_CTRL_BIT] ? {22'b0, !uart_ready, 9'b0} : 32'b0;


`ifdef BENCH
   always @(posedge clk) begin
      if(uart_valid) begin
	 $write("%c", mem_wdata[7:0] );
	 $fflush(32'h8000_0001);
      end
   end
`endif

endmodule