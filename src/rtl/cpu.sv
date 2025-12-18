`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"
module cpu (
  input  logic clk,
  input  logic rst_n,
  imem_if.master instr,
  simple_bus_if.master data
);
  import soc_pkg::*;
  typedef enum logic [2:0] {
    FETCH_INSTR = 3'd0,
    WAIT_INSTR  = 3'd1,
    EXECUTE     = 3'd2,
    LOAD        = 3'd3,
    WAIT_DATA   = 3'd4,
    STORE       = 3'd5
  } state_t;

  state_t state;

  logic [63:0] csr_cycle;
  logic [63:0] csr_instret;

  logic [31:0] PC;
  logic [31:0] instr_word;

  logic [31:0] reg_bank [0:31];
  logic [31:0] rs1;
  logic [31:0] rs2;

  logic [4:0] rdId;
  logic [2:0] funct3;
  logic [6:0] funct7;

  logic [31:0] Uimm, Iimm, Simm, Bimm, Jimm;

  logic isALUreg, isALUimm, isBranch, isJALR, isJAL, isAUIPC, isLUI, isLoad, isStore, isSYSTEM;
  logic isEBREAK, isCSRRS;

  always_comb begin
    rdId   = instr_word[11:7];
    funct3 = instr_word[14:12];
    funct7 = instr_word[31:25];

    isALUreg = (instr_word[6:0] == 7'b0110011);
    isALUimm = (instr_word[6:0] == 7'b0010011);
    isBranch = (instr_word[6:0] == 7'b1100011);
    isJALR   = (instr_word[6:0] == 7'b1100111);
    isJAL    = (instr_word[6:0] == 7'b1101111);
    isAUIPC  = (instr_word[6:0] == 7'b0010111);
    isLUI    = (instr_word[6:0] == 7'b0110111);
    isLoad   = (instr_word[6:0] == 7'b0000011);
    isStore  = (instr_word[6:0] == 7'b0100011);
    isSYSTEM = (instr_word[6:0] == 7'b1110011);

    isEBREAK = isSYSTEM && (funct3 == 3'b000);
    isCSRRS  = isSYSTEM && (funct3 == 3'b010);

    Uimm = {instr_word[31], instr_word[30:12], 12'b0};
    Iimm = {{21{instr_word[31]}}, instr_word[30:20]};
    Simm = {{21{instr_word[31]}}, instr_word[30:25], instr_word[11:7]};
    Bimm = {{20{instr_word[31]}}, instr_word[7], instr_word[30:25], instr_word[11:8], 1'b0};
    Jimm = {{12{instr_word[31]}}, instr_word[19:12], instr_word[20], instr_word[30:21], 1'b0};
  end

  logic [31:0] CSR_data;
  always_comb begin
    CSR_data =
      ( instr_word[27] & instr_word[21]) ? csr_instret[63:32] :
      (~instr_word[27] & instr_word[21]) ? csr_instret[31:0]  :
            instr_word[27]               ? csr_cycle[63:32]   :
                                           csr_cycle[31:0];
  end

  // ---------------------- ALU ----------------------
  logic [31:0] aluIn1, aluIn2;
  logic [31:0] aluOut;
  logic [4:0] shamt;
  logic [31:0] aluPlus;
  logic [32:0] aluMinus;
  logic EQ, LTU, LT;

  always_comb begin
    aluIn1 = rs1;
    aluIn2 =
      isALUreg ? rs2 :
      isBranch ? rs2 :
      isALUimm ? Iimm :
      isStore  ? Simm :
      isLoad   ? Iimm :
      isJALR   ? Iimm :
      isAUIPC  ? Uimm :
      isLUI    ? Uimm :
      32'b0;

    shamt  = isALUreg ? rs2[4:0] : instr_word[24:20];
    aluPlus  = aluIn1 + aluIn2;
    aluMinus = {1'b1, ~aluIn2} + {1'b0, aluIn1} + 33'b1;
    EQ  = (aluMinus[31:0] == 32'b0);
    LTU = aluMinus[32];
    LT  = (aluIn1[31] ^ aluIn2[31]) ? aluIn1[31] : aluMinus[32];

    unique case (funct3)
      3'b000: aluOut = (funct7[5] & instr_word[5]) ? aluMinus[31:0] : aluPlus;
      3'b001: aluOut = aluIn1 << shamt;
      3'b010: aluOut = {31'b0, LT};
      3'b011: aluOut = {31'b0, LTU};
      3'b100: aluOut = (aluIn1 ^ aluIn2);
      3'b101: aluOut = funct7[5] ? ($signed(aluIn1) >>> shamt) : (aluIn1 >> shamt);
      3'b110: aluOut = (aluIn1 | aluIn2);
      3'b111: aluOut = (aluIn1 & aluIn2);
      default: aluOut = 32'b0;
    endcase
  end

  logic takeBranch;
  always_comb begin
    unique case (funct3)
      3'b000: takeBranch = EQ;
      3'b001: takeBranch = ~EQ;
      3'b100: takeBranch = LT;
      3'b101: takeBranch = ~LT;
      3'b110: takeBranch = LTU;
      3'b111: takeBranch = ~LTU;
      default: takeBranch = 1'b0;
    endcase
  end

  logic [31:0] PCplusImm;
  logic [31:0] PCplus4;
  always_comb begin
    PCplusImm = PC + (instr_word[3] ? Jimm :
                      instr_word[4] ? Uimm :
                                      Bimm);
    PCplus4   = PC + 32'd4;
  end

  logic [31:0] nextPC;
  always_comb begin
    nextPC =
      (isBranch && takeBranch) ? PCplusImm :
      isJALR                  ? {aluPlus[31:1], 1'b0} :
      isJAL                   ? PCplusImm :
                                PCplus4;
  end

  // ---------------------- Memory access ----------------------
  logic [31:0] loadstore_addr;
  logic mem_byteAccess, mem_halfwordAccess;
  logic [15:0] LOAD_half;
  logic [7:0]  LOAD_byte;
  logic LOAD_sign;
  logic [31:0] LOAD_data;
  logic [3:0]  STORE_wmask;
  logic [31:0] STORE_wdata;

  always_comb begin
    loadstore_addr = rs1 + (isStore ? Simm : Iimm);

    mem_byteAccess     = (funct3[1:0] == 2'b00);
    mem_halfwordAccess = (funct3[1:0] == 2'b01);

    LOAD_half = loadstore_addr[1] ? data.rdata[31:16] : data.rdata[15:0];
    LOAD_byte = loadstore_addr[0] ? LOAD_half[15:8] : LOAD_half[7:0];
    LOAD_sign = ~funct3[2] & (mem_byteAccess ? LOAD_byte[7] : LOAD_half[15]);
    LOAD_data =
      mem_byteAccess      ? {{24{LOAD_sign}}, LOAD_byte} :
      mem_halfwordAccess  ? {{16{LOAD_sign}}, LOAD_half} :
                            data.rdata;

    STORE_wdata[7:0]   = rs2[7:0];
    STORE_wdata[15:8]  = loadstore_addr[0] ? rs2[7:0] : rs2[15:8];
    STORE_wdata[23:16] = loadstore_addr[1] ? rs2[7:0] : rs2[23:16];
    STORE_wdata[31:24] = loadstore_addr[0] ? rs2[7:0] :
                         loadstore_addr[1] ? rs2[15:8] : rs2[31:24];

    STORE_wmask =
      mem_byteAccess ? (loadstore_addr[1] ?
                        (loadstore_addr[0] ? 4'b1000 : 4'b0100) :
                        (loadstore_addr[0] ? 4'b0010 : 4'b0001)) :
      mem_halfwordAccess ? (loadstore_addr[1] ? 4'b1100 : 4'b0011) :
                           4'b1111;
  end

  logic [31:0] writeBackData;
  logic writeBackEn;
  always_comb begin
    writeBackData =
      isALUreg ? aluOut :
      isALUimm ? aluOut :
      isJALR   ? PCplus4 :
      isJAL    ? PCplus4 :
      isLUI    ? Uimm :
      isAUIPC  ? PCplusImm :
      isLoad   ? LOAD_data :
      isCSRRS  ? CSR_data :
                32'b0;

    writeBackEn =
      ((state == EXECUTE) && (isALUreg || isALUimm || isJAL || isJALR || isLUI || isAUIPC || isCSRRS)) ||
      ((state == WAIT_DATA) && isLoad);
  end

  // ---------------------- Bus driving ----------------------
  always_comb begin
    instr.addr = PC;
    instr.ren  = (state == FETCH_INSTR) || (state == WAIT_INSTR);

    data.addr  = loadstore_addr;
    data.ren   = (state == LOAD);
    data.wen   = (state == STORE);
    data.wdata = STORE_wdata;
    data.wstrb = (state == STORE) ? STORE_wmask : 4'b0000;
  end

  // ---------------------- Sequential ----------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= FETCH_INSTR;
      PC          <= 32'b0;
      instr_word  <= 32'b0;
      rs1         <= 32'b0;
      rs2         <= 32'b0;
      csr_cycle   <= 64'b0;
      csr_instret <= 64'b0;
    end else begin
      csr_cycle <= csr_cycle + 64'd1;
      if (state == WAIT_INSTR) begin
        csr_instret <= csr_instret + 64'd1;
      end

      if (writeBackEn && (rdId != 0)) begin
        reg_bank[rdId] <= writeBackData;
      end

      unique case (state)
        FETCH_INSTR: begin
          state <= WAIT_INSTR;
        end
        WAIT_INSTR: begin
          instr_word <= instr.rdata;
          rs1 <= reg_bank[instr.rdata[19:15]];
          rs2 <= reg_bank[instr.rdata[24:20]];
          state <= EXECUTE;
        end
        EXECUTE: begin
          if (!isEBREAK) begin
            PC <= nextPC;
          end
          if (isLoad) begin
            state <= LOAD;
          end else if (isStore) begin
            state <= STORE;
          end else begin
            state <= FETCH_INSTR;
          end
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
        default: begin
          state <= FETCH_INSTR;
        end
      endcase
    end
  end

  `ifdef BENCH
    integer i;
    initial begin
      for (i = 0; i < 32; ++i) begin
        reg_bank[i] = 0;
      end
    end
  `endif
endmodule
