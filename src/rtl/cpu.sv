`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"
module cpu (
  input  logic clk,
  input  logic rst_n,
  imem_if.master instr,
  simple_bus_if.master data
);
  import soc_pkg::*;
  // ---------------------- CSRs ----------------------
  logic [63:0] csr_cycle;
  logic [63:0] csr_instret;

  // ---------------------- Register file ----------------------
  logic [31:0] reg_bank [0:31];

  // ---------------------- Pipeline ----------------------
  // IF:   pc_f -> instruction fetch address
  // F2:   instr.rdata + if_pc/if_valid (registered ROM output + associated PC)
  // ID:   id_instr/id_pc/id_valid (explicitly registered to keep ROM usage BRAM-friendly)
  // EX:   id_ex_*
  // MEM:  ex_mem_*
  // WB:   mem_wb_* (+ data.rdata for loads)

  logic halted;

  // ---------------------- IF stage ----------------------
  logic [31:0] pc_f;

  // F2 stage (PC+valid only; instruction comes from instr.rdata).
  logic        if_valid;
  logic [31:0] if_pc;

  // ---------------------- ID stage ----------------------
  // ID stage instruction is explicitly registered to avoid combinational feedback
  // from PROGROM read-data into its own control/addressing (BSRAM inference-friendly).
  logic        id_valid;
  logic [31:0] id_pc;
  logic [31:0] id_instr;

  logic [31:0] instr_d;
  logic [6:0]  opcode_d;
  logic [4:0]  rs1_d, rs2_d, rd_d;
  logic [2:0]  funct3_d;
  logic [6:0]  funct7_d;

  logic [31:0] Uimm_d, Iimm_d, Simm_d, Bimm_d, Jimm_d;

  logic isALUreg_d, isALUimm_d, isBranch_d, isJALR_d, isJAL_d, isAUIPC_d, isLUI_d;
  logic isLoad_d, isStore_d, isSYSTEM_d, isEBREAK_d, isCSRRS_d;

  logic uses_rs1_d, uses_rs2_d;

  logic [31:0] rs1_val_d, rs2_val_d;

  assign instr_d  = id_instr;
  assign opcode_d = instr_d[6:0];
  assign rd_d     = instr_d[11:7];
  assign funct3_d = instr_d[14:12];
  assign rs1_d    = instr_d[19:15];
  assign rs2_d    = instr_d[24:20];
  assign funct7_d = instr_d[31:25];

  always_comb begin
    isALUreg_d = id_valid && (opcode_d == 7'b0110011);
    isALUimm_d = id_valid && (opcode_d == 7'b0010011);
    isBranch_d = id_valid && (opcode_d == 7'b1100011);
    isJALR_d   = id_valid && (opcode_d == 7'b1100111);
    isJAL_d    = id_valid && (opcode_d == 7'b1101111);
    isAUIPC_d  = id_valid && (opcode_d == 7'b0010111);
    isLUI_d    = id_valid && (opcode_d == 7'b0110111);
    isLoad_d   = id_valid && (opcode_d == 7'b0000011);
    isStore_d  = id_valid && (opcode_d == 7'b0100011);
    isSYSTEM_d = id_valid && (opcode_d == 7'b1110011);

    isEBREAK_d = isSYSTEM_d && (funct3_d == 3'b000);
    isCSRRS_d  = isSYSTEM_d && (funct3_d == 3'b010);

    // Register usage (avoid false hazards on U/J types).
    uses_rs1_d = isALUreg_d || isALUimm_d || isBranch_d || isJALR_d || isLoad_d || isStore_d;
    uses_rs2_d = isALUreg_d || isBranch_d || isStore_d;

    Uimm_d = {instr_d[31], instr_d[30:12], 12'b0};
    Iimm_d = {{21{instr_d[31]}}, instr_d[30:20]};
    Simm_d = {{21{instr_d[31]}}, instr_d[30:25], instr_d[11:7]};
    Bimm_d = {{20{instr_d[31]}}, instr_d[7], instr_d[30:25], instr_d[11:8], 1'b0};
    Jimm_d = {{12{instr_d[31]}}, instr_d[19:12], instr_d[20], instr_d[30:21], 1'b0};
  end

  always_comb begin
    rs1_val_d = 32'b0;
    rs2_val_d = 32'b0;

    if (rs1_d != 5'd0) begin
      rs1_val_d = (wb_we && (mem_wb_rd == rs1_d)) ? wb_value : reg_bank[rs1_d];
    end

    if (rs2_d != 5'd0) begin
      rs2_val_d = (wb_we && (mem_wb_rd == rs2_d)) ? wb_value : reg_bank[rs2_d];
    end
  end

  // ---------------------- ID/EX pipeline regs ----------------------
  logic        id_ex_valid;
  logic [31:0] id_ex_pc;
  logic [31:0] id_ex_instr;
  logic [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
  logic [2:0]  id_ex_funct3;
  logic [6:0]  id_ex_funct7;
  logic [31:0] id_ex_rs1_val, id_ex_rs2_val;
  logic [31:0] id_ex_Uimm, id_ex_Iimm, id_ex_Simm, id_ex_Bimm, id_ex_Jimm;
  logic        id_ex_isALUreg, id_ex_isALUimm, id_ex_isBranch, id_ex_isJALR, id_ex_isJAL;
  logic        id_ex_isAUIPC, id_ex_isLUI, id_ex_isLoad, id_ex_isStore, id_ex_isCSRRS, id_ex_isEBREAK;

  // ---------------------- EX stage (with forwarding) ----------------------
  logic [31:0] ex_rs1, ex_rs2;

  logic ex_redirect;
  logic [31:0] ex_redirect_pc;
  logic [31:0] ex_jalr_sum;

  logic [31:0] ex_alu_in2;
  logic [31:0] ex_alu_out;

  logic ex_eq, ex_ltu, ex_lt;
  logic ex_take_branch;

  logic [31:0] ex_pc_plus4;
  logic [31:0] ex_pc_plus_bimm;
  logic [31:0] ex_pc_plus_jimm;
  logic [31:0] ex_pc_plus_uimm;

  logic [31:0] ex_addr;
  logic [31:0] ex_store_wdata;
  logic [3:0]  ex_store_wmask;

  logic        ex_wb_en;
  logic [31:0] ex_wb_value;

  logic [31:0] ex_csr_rdata;

  // ---------------------- EX/MEM pipeline regs ----------------------
  logic        ex_mem_valid;
  logic [4:0]  ex_mem_rd;
  logic        ex_mem_isLoad, ex_mem_isStore;
  logic [2:0]  ex_mem_funct3;
  logic [31:0] ex_mem_addr;
  logic [31:0] ex_mem_store_wdata;
  logic [3:0]  ex_mem_store_wmask;
  logic        ex_mem_wb_en;
  logic [31:0] ex_mem_wb_value;

  // ---------------------- MEM/WB pipeline regs ----------------------
  logic        mem_wb_valid;
  logic [4:0]  mem_wb_rd;
  logic        mem_wb_isLoad;
  logic [2:0]  mem_wb_funct3;
  logic [1:0]  mem_wb_addr_low;
  logic        mem_wb_wb_en;
  logic [31:0] mem_wb_wb_value;

  // ---------------------- WB stage ----------------------
  logic [31:0] wb_load_data;
  logic [31:0] wb_value;
  logic        wb_we;

  // ---------------------- Hazard detection ----------------------
  logic stall_load_use;
  always_comb begin
    stall_load_use = 1'b0;
    if (id_valid && id_ex_valid && id_ex_isLoad && (id_ex_rd != 5'd0)) begin
      if ((uses_rs1_d && (id_ex_rd == rs1_d)) || (uses_rs2_d && (id_ex_rd == rs2_d))) begin
        stall_load_use = 1'b1;
      end
    end
  end

  // ---------------------- Forwarding selection ----------------------
  // Forward from EX/MEM for results available after EX (not loads).
  logic ex_mem_fwd_en;
  logic [31:0] wb_fwd_value;
  always_comb begin
    ex_mem_fwd_en = ex_mem_valid && ex_mem_wb_en && !ex_mem_isLoad && (ex_mem_rd != 5'd0);
    wb_fwd_value  = wb_value;

    ex_rs1 = id_ex_rs1_val;
    ex_rs2 = id_ex_rs2_val;

    if (ex_mem_fwd_en && (ex_mem_rd == id_ex_rs1)) begin
      ex_rs1 = ex_mem_wb_value;
    end else if (mem_wb_valid && mem_wb_wb_en && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1)) begin
      ex_rs1 = wb_fwd_value;
    end

    if (ex_mem_fwd_en && (ex_mem_rd == id_ex_rs2)) begin
      ex_rs2 = ex_mem_wb_value;
    end else if (mem_wb_valid && mem_wb_wb_en && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2)) begin
      ex_rs2 = wb_fwd_value;
    end
  end

  // ---------------------- CSR read (only cycle/instret) ----------------------
  always_comb begin
    ex_csr_rdata =
      ( id_ex_instr[27] & id_ex_instr[21]) ? csr_instret[63:32] :
      (~id_ex_instr[27] & id_ex_instr[21]) ? csr_instret[31:0]  :
            id_ex_instr[27]               ? csr_cycle[63:32]   :
                                             csr_cycle[31:0];
  end

  // ---------------------- EX stage logic ----------------------
  always_comb begin
    logic [4:0] shamt;
    logic is_sub;
    logic mem_byteAccess, mem_halfwordAccess;

    shamt            = 5'b0;
    is_sub           = 1'b0;
    mem_byteAccess     = 1'b0;
    mem_halfwordAccess = 1'b0;

    // Defaults
    ex_alu_in2   = 32'b0;
    ex_alu_out   = 32'b0;

    ex_eq  = 1'b0;
    ex_ltu = 1'b0;
    ex_lt  = 1'b0;
    ex_take_branch = 1'b0;

    ex_pc_plus4    = id_ex_pc + 32'd4;
    ex_pc_plus_bimm = id_ex_pc + id_ex_Bimm;
    ex_pc_plus_jimm = id_ex_pc + id_ex_Jimm;
    ex_pc_plus_uimm = id_ex_pc + id_ex_Uimm;

    ex_addr = ex_rs1 + (id_ex_isStore ? id_ex_Simm : id_ex_Iimm);

    ex_store_wdata = 32'b0;
    ex_store_wmask = 4'b0000;

    ex_wb_en    = 1'b0;
    ex_wb_value = 32'b0;

    ex_redirect    = 1'b0;
    ex_redirect_pc = 32'b0;
    ex_jalr_sum    = 32'b0;

    // ALU operations (R/I)
    if (id_ex_isALUreg || id_ex_isALUimm) begin
      shamt  = id_ex_isALUreg ? ex_rs2[4:0] : id_ex_instr[24:20];
      is_sub = id_ex_isALUreg && id_ex_funct7[5];
      ex_alu_in2 = id_ex_isALUreg ? ex_rs2 : id_ex_Iimm;

      ex_eq  = (ex_rs1 == ex_alu_in2);
      ex_ltu = (ex_rs1 < ex_alu_in2);
      ex_lt  = ($signed(ex_rs1) < $signed(ex_alu_in2));

      unique case (id_ex_funct3)
        3'b000: ex_alu_out = is_sub ? (ex_rs1 - ex_alu_in2) : (ex_rs1 + ex_alu_in2);
        3'b001: ex_alu_out = ex_rs1 << shamt;
        3'b010: ex_alu_out = {31'b0, ex_lt};
        3'b011: ex_alu_out = {31'b0, ex_ltu};
        3'b100: ex_alu_out = (ex_rs1 ^ ex_alu_in2);
        3'b101: ex_alu_out = id_ex_funct7[5] ? ($signed(ex_rs1) >>> shamt) : (ex_rs1 >> shamt);
        3'b110: ex_alu_out = (ex_rs1 | ex_alu_in2);
        3'b111: ex_alu_out = (ex_rs1 & ex_alu_in2);
        default: ex_alu_out = 32'b0;
      endcase
    end

    // Branch compare uses rs1/rs2.
    if (id_ex_isBranch) begin
      ex_eq  = (ex_rs1 == ex_rs2);
      ex_ltu = (ex_rs1 < ex_rs2);
      ex_lt  = ($signed(ex_rs1) < $signed(ex_rs2));

      unique case (id_ex_funct3)
        3'b000: ex_take_branch = ex_eq;
        3'b001: ex_take_branch = ~ex_eq;
        3'b100: ex_take_branch = ex_lt;
        3'b101: ex_take_branch = ~ex_lt;
        3'b110: ex_take_branch = ex_ltu;
        3'b111: ex_take_branch = ~ex_ltu;
        default: ex_take_branch = 1'b0;
      endcase
    end

    // Store formatting.
    if (id_ex_isStore) begin
      mem_byteAccess     = (id_ex_funct3[1:0] == 2'b00);
      mem_halfwordAccess = (id_ex_funct3[1:0] == 2'b01);

      ex_store_wdata[7:0]   = ex_rs2[7:0];
      ex_store_wdata[15:8]  = ex_addr[0] ? ex_rs2[7:0] : ex_rs2[15:8];
      ex_store_wdata[23:16] = ex_addr[1] ? ex_rs2[7:0] : ex_rs2[23:16];
      ex_store_wdata[31:24] = ex_addr[0] ? ex_rs2[7:0] :
                              ex_addr[1] ? ex_rs2[15:8] : ex_rs2[31:24];

      ex_store_wmask =
        mem_byteAccess ? (ex_addr[1] ?
                          (ex_addr[0] ? 4'b1000 : 4'b0100) :
                          (ex_addr[0] ? 4'b0010 : 4'b0001)) :
        mem_halfwordAccess ? (ex_addr[1] ? 4'b1100 : 4'b0011) :
                             4'b1111;
    end

    // Writeback selection (loads get data in WB stage).
    if (id_ex_valid) begin
      if (id_ex_isALUreg || id_ex_isALUimm) begin
        ex_wb_en    = 1'b1;
        ex_wb_value = ex_alu_out;
      end else if (id_ex_isJAL || id_ex_isJALR) begin
        ex_wb_en    = 1'b1;
        ex_wb_value = ex_pc_plus4;
      end else if (id_ex_isLUI) begin
        ex_wb_en    = 1'b1;
        ex_wb_value = id_ex_Uimm;
      end else if (id_ex_isAUIPC) begin
        ex_wb_en    = 1'b1;
        ex_wb_value = ex_pc_plus_uimm;
      end else if (id_ex_isCSRRS) begin
        ex_wb_en    = 1'b1;
        ex_wb_value = ex_csr_rdata;
      end else if (id_ex_isLoad) begin
        ex_wb_en    = 1'b1;
        ex_wb_value = 32'b0;
      end
    end

    // Control transfer resolution in EX.
    ex_redirect =
      id_ex_valid && ((id_ex_isBranch && ex_take_branch) || id_ex_isJALR || id_ex_isJAL);

    ex_jalr_sum = ex_rs1 + id_ex_Iimm;

    ex_redirect_pc =
      (id_ex_isBranch && ex_take_branch) ? ex_pc_plus_bimm :
      id_ex_isJALR ? { ex_jalr_sum[31:1], 1'b0 } :
      id_ex_isJAL  ? ex_pc_plus_jimm :
                    32'b0;
  end

  // ---------------------- WB load formatting ----------------------
  always_comb begin
    logic mem_byteAccess, mem_halfwordAccess;
    logic [15:0] load_half;
    logic [7:0]  load_byte;
    logic load_sign;

    mem_byteAccess     = (mem_wb_funct3[1:0] == 2'b00);
    mem_halfwordAccess = (mem_wb_funct3[1:0] == 2'b01);

    load_half = mem_wb_addr_low[1] ? data.rdata[31:16] : data.rdata[15:0];
    load_byte = mem_wb_addr_low[0] ? load_half[15:8] : load_half[7:0];
    load_sign = ~mem_wb_funct3[2] & (mem_byteAccess ? load_byte[7] : load_half[15]);

    wb_load_data =
      mem_byteAccess     ? {{24{load_sign}}, load_byte} :
      mem_halfwordAccess ? {{16{load_sign}}, load_half} :
                           data.rdata;
  end

  always_comb begin
    wb_value = mem_wb_isLoad ? wb_load_data : mem_wb_wb_value;
    wb_we    = mem_wb_valid && mem_wb_wb_en && (mem_wb_rd != 5'd0);
  end

  // ---------------------- Bus driving ----------------------
  always_comb begin
    // Keep instruction ROM access BRAM-friendly:
    // - Never feed ROM read-data back into ROM control/address combinationally.
    // - During a load-use stall, hold the F2 stage (`instr.rdata` + `if_pc`) stable so it can
    //   be transferred into the ID register once the stall clears.
    instr.addr = stall_load_use ? if_pc : pc_f;
    instr.ren  = !halted;

    data.addr  = ex_mem_addr;
    data.ren   = !halted && ex_mem_valid && ex_mem_isLoad;
    data.wen   = !halted && ex_mem_valid && ex_mem_isStore;
    data.wdata = ex_mem_store_wdata;
    data.wstrb = (!halted && ex_mem_valid && ex_mem_isStore) ? ex_mem_store_wmask : 4'b0000;
  end

  // ---------------------- Sequential ----------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      halted      <= 1'b0;
      pc_f        <= 32'b0;
      if_valid    <= 1'b0;
      if_pc       <= 32'b0;
      id_valid    <= 1'b0;
      id_pc       <= 32'b0;
      id_instr    <= 32'b0;

      id_ex_valid <= 1'b0;
      id_ex_pc    <= 32'b0;
      id_ex_instr <= 32'b0;
      id_ex_rs1   <= 5'b0;
      id_ex_rs2   <= 5'b0;
      id_ex_rd    <= 5'b0;
      id_ex_funct3 <= 3'b0;
      id_ex_funct7 <= 7'b0;
      id_ex_rs1_val <= 32'b0;
      id_ex_rs2_val <= 32'b0;
      id_ex_Uimm <= 32'b0;
      id_ex_Iimm <= 32'b0;
      id_ex_Simm <= 32'b0;
      id_ex_Bimm <= 32'b0;
      id_ex_Jimm <= 32'b0;
      id_ex_isALUreg <= 1'b0;
      id_ex_isALUimm <= 1'b0;
      id_ex_isBranch <= 1'b0;
      id_ex_isJALR   <= 1'b0;
      id_ex_isJAL    <= 1'b0;
      id_ex_isAUIPC  <= 1'b0;
      id_ex_isLUI    <= 1'b0;
      id_ex_isLoad   <= 1'b0;
      id_ex_isStore  <= 1'b0;
      id_ex_isCSRRS  <= 1'b0;
      id_ex_isEBREAK <= 1'b0;

      ex_mem_valid <= 1'b0;
      ex_mem_rd    <= 5'b0;
      ex_mem_isLoad <= 1'b0;
      ex_mem_isStore <= 1'b0;
      ex_mem_funct3 <= 3'b0;
      ex_mem_addr  <= 32'b0;
      ex_mem_store_wdata <= 32'b0;
      ex_mem_store_wmask <= 4'b0;
      ex_mem_wb_en <= 1'b0;
      ex_mem_wb_value <= 32'b0;

      mem_wb_valid <= 1'b0;
      mem_wb_rd    <= 5'b0;
      mem_wb_isLoad <= 1'b0;
      mem_wb_funct3 <= 3'b0;
      mem_wb_addr_low <= 2'b0;
      mem_wb_wb_en <= 1'b0;
      mem_wb_wb_value <= 32'b0;

      csr_cycle   <= 64'b0;
      csr_instret <= 64'b0;
    end else begin
      logic halt_now;
      halt_now = (!halted && id_ex_valid && id_ex_isEBREAK);

      // Cycle counter always runs.
      csr_cycle <= csr_cycle + 64'd1;

      // Retire / writeback
      if (!halted) begin
        if (wb_we) begin
          reg_bank[mem_wb_rd] <= wb_value;
        end
        if (mem_wb_valid) begin
          csr_instret <= csr_instret + 64'd1;
        end
      end

      if (halt_now) begin
        halted <= 1'b1;
      end

      // IF stage
      if (!halted && !halt_now && !stall_load_use) begin
        if_pc    <= pc_f;
        if_valid <= ex_redirect ? 1'b0 : 1'b1;

        pc_f <= ex_redirect ? ex_redirect_pc : (pc_f + 32'd4);
      end else if (!halted && halt_now) begin
        if_valid <= 1'b0;
      end

      // ID stage (register instruction from PROGROM)
      if (!halted) begin
        if (halt_now || ex_redirect) begin
          id_valid <= 1'b0;
          id_pc    <= 32'b0;
          id_instr <= 32'h0000_0013; // NOP
        end else if (!stall_load_use) begin
          id_valid <= if_valid;
          id_pc    <= if_pc;
          id_instr <= instr.rdata;
        end
      end

      // ID/EX update (bubble on stall/flush)
      if (!halted) begin
        if (halt_now || ex_redirect || stall_load_use) begin
          id_ex_valid <= 1'b0;
        end else begin
          id_ex_valid  <= id_valid;
          id_ex_pc     <= id_pc;
          id_ex_instr  <= id_instr;
          id_ex_rs1    <= rs1_d;
          id_ex_rs2    <= rs2_d;
          id_ex_rd     <= rd_d;
          id_ex_funct3 <= funct3_d;
          id_ex_funct7 <= funct7_d;
          id_ex_rs1_val <= rs1_val_d;
          id_ex_rs2_val <= rs2_val_d;
          id_ex_Uimm   <= Uimm_d;
          id_ex_Iimm   <= Iimm_d;
          id_ex_Simm   <= Simm_d;
          id_ex_Bimm   <= Bimm_d;
          id_ex_Jimm   <= Jimm_d;
          id_ex_isALUreg <= isALUreg_d;
          id_ex_isALUimm <= isALUimm_d;
          id_ex_isBranch <= isBranch_d;
          id_ex_isJALR   <= isJALR_d;
          id_ex_isJAL    <= isJAL_d;
          id_ex_isAUIPC  <= isAUIPC_d;
          id_ex_isLUI    <= isLUI_d;
          id_ex_isLoad   <= isLoad_d;
          id_ex_isStore  <= isStore_d;
          id_ex_isCSRRS  <= isCSRRS_d;
          id_ex_isEBREAK <= isEBREAK_d;
        end
      end

      // EX/MEM update
      if (!halted) begin
        ex_mem_valid <= id_ex_valid;
        ex_mem_rd    <= id_ex_rd;
        ex_mem_isLoad  <= id_ex_isLoad;
        ex_mem_isStore <= id_ex_isStore;
        ex_mem_funct3  <= id_ex_funct3;
        ex_mem_addr    <= ex_addr;
        ex_mem_store_wdata <= ex_store_wdata;
        ex_mem_store_wmask <= ex_store_wmask;
        ex_mem_wb_en    <= ex_wb_en;
        ex_mem_wb_value <= ex_wb_value;
      end

      // MEM/WB update
      if (!halted) begin
        mem_wb_valid <= ex_mem_valid;
        mem_wb_rd    <= ex_mem_rd;
        mem_wb_isLoad <= ex_mem_isLoad;
        mem_wb_funct3 <= ex_mem_funct3;
        mem_wb_addr_low <= ex_mem_addr[1:0];
        mem_wb_wb_en <= ex_mem_wb_en;
        mem_wb_wb_value <= ex_mem_wb_value;
      end
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
