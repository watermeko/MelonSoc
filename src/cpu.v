module cpu(
    input clk,
    input rst_n,
    output [31:0] mem_addr,
    input [31:0] mem_rdata,
    output mem_ren,
    output [31:0] mem_wdata,
    output [3:0] mem_wmask
);

reg [31:0] PC=0;
reg [31:0] instr;

wire isALUreg =  (instr[6:0] == 7'b0110011); // rd <- rs1 OP rs2
wire isALUimm =  (instr[6:0] == 7'b0010011); // rd <- rs1 OP Iimm
wire isBranch = (instr[6:0] == 7'b1100011); // branch
wire isJALR   = (instr[6:0] == 7'b1100111); // JALR
wire isJAL    = (instr[6:0] == 7'b1101111); // JAL
wire isAUIPC = (instr[6:0] == 7'b0010111); // AUIPC
wire isLUI   = (instr[6:0] == 7'b0110111); // LUI
wire isLoad  = (instr[6:0] == 7'b0000011); // LOAD
wire isStore = (instr[6:0] == 7'b0100011); // STORE
wire isSYSTEM = (instr[6:0] == 7'b1110011); // SYSTEM
// The 5 immediate formats
wire [31:0] Uimm = {instr[31], instr[30:12], {12{1'b0}}};
wire [31:0] Iimm = {{21{instr[31]}}, instr[30:20]};
wire [31:0] Simm = {{21{instr[31]}}, instr[30:25], instr[11:7]};
wire [31:0] Bimm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
wire [31:0] Jimm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
// Source and destination registers
wire [4:0] rs1Id = instr[19:15];
wire [4:0] rs2Id = instr[24:20];
wire [4:0] rdId  = instr[11:7];
// function codes
wire [2:0] funct3 = instr[14:12];
wire [6:0] funct7 = instr[31:25];
// The registers bank
reg [31:0] reg_bank [0:31];
reg [31:0] rs1;
reg [31:0] rs2;
wire [31:0] writeBackData;
wire        writeBackEn;


// ---------------EXECUTION UNIT-----------------
localparam FETCH_INSTR = 0;
localparam WAIT_INSTR = 1;
localparam FETCH_REGS = 2;
localparam EXECUTE = 3;
localparam LOAD = 4;
localparam WAIT_DATA = 5;
localparam STORE = 6;

reg [2:0] state = FETCH_INSTR;

always @(posedge clk or negedge rst_n) begin
  // `ifdef  BENCH
  // if (PC <= 32'd20) begin
  // $display("T=%0t CPU: clk=%b rst_n=%b PC=%h state=%d instr=%h mem_ren=%b mem_wmask=%b mem_addr=%h cpu.isStore=%b cpu.isSYSTEM=%b",
  //            $time, clk, rst_n, PC, state, instr, mem_ren, mem_wmask, mem_addr, isStore, isSYSTEM); // 添加你关心的信号
  // end
  // `endif 
  if (!rst_n) begin
    state <= FETCH_INSTR;
    PC <= 0;
  end else begin
    if(writeBackEn && rdId != 0) begin
      reg_bank[rdId] <= writeBackData;
// `ifdef BENCH	 
// 	    $display("x%0d <= %b",rdId,writeBackData);
// `endif	
    end

    case (state)
      FETCH_INSTR: begin
        state <= WAIT_INSTR;
      end
      WAIT_INSTR: begin
        instr <= mem_rdata;
        state <= FETCH_REGS;
      end
      FETCH_REGS: begin
        rs1 <= reg_bank[rs1Id];
        rs2 <= reg_bank[rs2Id];
        state <= EXECUTE;
      end
      EXECUTE: begin
        if(!isSYSTEM) begin
          PC <= nextPC;
        end
        state <= isLoad ? LOAD :
                  isStore ? STORE :
                  FETCH_INSTR; 
        `ifdef BENCH
        if(isSYSTEM) $finish();
        `endif
      end
      LOAD: begin
        state <= WAIT_DATA;
      end
      WAIT_DATA: begin
        state <= FETCH_INSTR;
      end
      STORE: begin
        state <= FETCH_INSTR;
      end
    endcase
  end
end


// ----------------------ALU----------------------
wire [31:0] aluIn1 = rs1;
wire [31:0] aluIn2 = isALUreg ? rs2 : 
                      isBranch ? rs2 :
                      isALUimm ? Iimm :
                      isStore  ? Simm :
                      isLoad   ? Simm :
                      isAUIPC  ? Uimm :
                      isLUI    ? Uimm :
                      0;
reg [31:0] aluOut;
wire [4:0] shamt = isALUreg?rs2[4:0]:instr[24:20];

wire [31:0] aluPlus = aluIn1 + aluIn2;
wire [32:0] aluMinus = {1'b1,~aluIn2} + {1'b0,aluIn1} + 33'b1;
wire EQ = (aluMinus[31:0] == 0);
wire LTU = aluMinus[32];
wire LT = (aluIn1[31] ^ aluIn2[31]) ? aluIn1[31] : aluMinus[32];

// 没有使用节省移位器的方法
always @(*) begin
  case(funct3)
    3'b000: aluOut = (funct7[5] & instr[5]) ? aluMinus : aluPlus;
    3'b001: aluOut = aluIn1 << shamt;
    3'b010: aluOut = {31'b0,LT}; 
    3'b011: aluOut = {31'b0,LTU};
    3'b100: aluOut = (aluIn1 ^ aluIn2);
    3'b101: aluOut = funct7[5]? ($signed(aluIn1) >>> shamt) : (aluIn1 >> shamt); 
    3'b110: aluOut = (aluIn1 | aluIn2);
    3'b111: aluOut = (aluIn1 & aluIn2);	
  endcase
end


reg takeBranch;
always @(*) begin
  case(funct3)
	3'b000: takeBranch = EQ; 
	3'b001: takeBranch = !EQ;
	3'b100: takeBranch = LT;
	3'b101: takeBranch = !LT;
	3'b110: takeBranch = LTU;
	3'b111: takeBranch = !LTU;
	default: takeBranch = 1'b0;
  endcase
end

wire [31:0] PCplusImm = PC + ( instr[3] ? Jimm[31:0] :
          instr[4] ? Uimm[31:0] :
                     Bimm[31:0] );
wire [31:0] PCplus4 = PC + 4;

assign writeBackData = isALUreg ? aluOut :
                        isALUimm ? aluOut :
                        isJALR   ? PCplus4 :
                        isJAL    ? PCplus4 :
                        isLUI    ? Uimm :
                        isAUIPC  ? PCplusImm:
                        isLoad   ? LOAD_data :
                        0;
assign writeBackEn = (state == EXECUTE&&(isALUreg||isALUimm||isJAL||isJALR||isLUI||isAUIPC)) |
                      (state == WAIT_DATA && isLoad); 

wire [31:0] nextPC = (isBranch&&takeBranch) ? PCplusImm :
                        isJALR   ? {aluPlus[31:1],1'b0} :
                        isJAL    ? PCplusImm :
                        PCplus4;







// ----------------------MEMORY----------------------
assign mem_addr =(state == WAIT_INSTR || state == FETCH_INSTR) ? PC : loadstore_addr;
assign mem_ren = (state == FETCH_INSTR || state == LOAD);
assign mem_wmask =  {4{(state == STORE)}} & STORE_wmask; 
// MEM LOAD
wire [31:0] loadstore_addr = rs1 + (isStore ? Simm : Iimm);

wire mem_byteAccess = funct3[1:0] == 2'b00;
wire mem_halfwordAccess = funct3[1:0] == 2'b01;

wire [15:0] LOAD_half = loadstore_addr[1] ? mem_rdata[31:16] : mem_rdata[15:0];
wire [7:0] LOAD_byte = loadstore_addr[0] ? LOAD_half[15:8] : LOAD_half[7:0];

wire LOAD_sign = !funct3[2] & (mem_byteAccess ? LOAD_byte[7] : LOAD_half[15]);
wire [31:0] LOAD_data = mem_byteAccess ? {{24{LOAD_sign}},LOAD_byte} :
                          mem_halfwordAccess ? {{16{LOAD_sign}},LOAD_half} :
                          mem_rdata;

// MEM STORE
assign mem_wdata[7:0] = rs2[7:0];
assign mem_wdata[15:8] = loadstore_addr[0] ? rs2[7:0] : rs2[15:8];
assign mem_wdata[23:16] = loadstore_addr[1] ? rs2[7:0] : rs2[23:16];
assign mem_wdata[31:24] = loadstore_addr[0] ? rs2[7:0] :
                          loadstore_addr[1] ? rs2[15:8] : rs2[31:24];

wire [3:0] STORE_wmask =
    mem_byteAccess      ?
          (loadstore_addr[1] ?
          (loadstore_addr[0] ? 4'b1000 : 4'b0100) :
          (loadstore_addr[0] ? 4'b0010 : 4'b0001)
                ) :
    mem_halfwordAccess ?
          (loadstore_addr[1] ? 4'b1100 : 4'b0011) :
            4'b1111;

`ifdef BENCH
   integer i;
   initial begin
      for(i=0; i<32; ++i) begin
   reg_bank[i] = 0;
      end
   end
`endif


endmodule