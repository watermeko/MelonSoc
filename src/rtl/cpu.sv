`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"
`include "lib/rvc.sv"
module cpu (
  input  logic clk,
  input  logic rst_n,
  imem_if.master instr,
  simple_bus_if.master data
);
  import soc_pkg::*;
  import rvc::*;
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
  logic halt_now;

  // ---------------------- Division state machine ----------------------
  logic [31:0] div_dividend;
  logic [62:0] div_divisor;
  logic [31:0] div_quotient;
  logic [31:0] div_quotient_msk;
  logic        div_sign;
  logic        div_busy = 1'b0;
  logic [31:0] div_result_q;  // Final quotient result
  logic [31:0] div_result_r;  // Final remainder result
  logic        div_result_valid = 1'b0;

  // ---------------------- IF stage ----------------------
  // Word-fetch PC (4-byte aligned) and a small halfword buffer for RVC.
  logic [31:0] pc_f;
  logic        if_valid; // indicates an in-flight ROM word on instr.rdata to be captured
  logic [31:0] if_pc;    // word address associated with instr.rdata (for debug / bring-up)
  logic [31:0] f2_word;  // registered copy of instr.rdata (BRAM-friendly)
  logic        f2_valid; // indicates f2_word will be appended into ibuf this cycle

  localparam int unsigned IBUF_HW_MAX = 8;
  logic [16*IBUF_HW_MAX-1:0] ibuf;
  logic [$clog2(IBUF_HW_MAX+1)-1:0] ibuf_hw_count;
  logic [31:0] pc_i;          // next instruction PC to issue (byte address)
  logic        drop_halfword; // drop low halfword once after redirect to 2-byte boundary
  logic        fetch_req;

  // ---------------------- ID stage ----------------------
  // ID stage instruction is explicitly registered to avoid combinational feedback
  // from PROGROM read-data into its own control/addressing (BSRAM inference-friendly).
  logic        id_valid;
  logic [31:0] id_pc;
  logic [31:0] id_instr;
  logic [31:0] id_len;

  logic [31:0] instr_d;
  logic [6:0]  opcode_d;
  logic [4:0]  rs1_d, rs2_d, rd_d;
  logic [2:0]  funct3_d;
  logic [6:0]  funct7_d;

  logic [31:0] Uimm_d, Iimm_d, Simm_d, Bimm_d, Jimm_d;

  logic isALUreg_d, isALUimm_d, isBranch_d, isJALR_d, isJAL_d, isAUIPC_d, isLUI_d;
  logic isLoad_d, isStore_d, isSYSTEM_d, isEBREAK_d, isCSRRS_d;
  logic isMUL_d, isDIV_d;

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
    isALUreg_d = id_valid && (opcode_d == 7'b0110011) && (funct7_d != 7'b0000001);
    isALUimm_d = id_valid && (opcode_d == 7'b0010011);
    isBranch_d = id_valid && (opcode_d == 7'b1100011);
    isJALR_d   = id_valid && (opcode_d == 7'b1100111);
    isJAL_d    = id_valid && (opcode_d == 7'b1101111);
    isAUIPC_d  = id_valid && (opcode_d == 7'b0010111);
    isLUI_d    = id_valid && (opcode_d == 7'b0110111);
    isLoad_d   = id_valid && (opcode_d == 7'b0000011);
    isStore_d  = id_valid && (opcode_d == 7'b0100011);
    isSYSTEM_d = id_valid && (opcode_d == 7'b1110011);

    // M extension instructions
    isMUL_d = id_valid && (opcode_d == 7'b0110011) && (funct7_d == 7'b0000001) && (funct3_d[2] == 1'b0);
    isDIV_d = id_valid && (opcode_d == 7'b0110011) && (funct7_d == 7'b0000001) && (funct3_d[2] == 1'b1);

    isEBREAK_d = isSYSTEM_d && (funct3_d == 3'b000);
    isCSRRS_d  = isSYSTEM_d && (funct3_d == 3'b010);

    // Register usage (avoid false hazards on U/J types).
    uses_rs1_d = isALUreg_d || isALUimm_d || isBranch_d || isJALR_d || isLoad_d || isStore_d || isMUL_d || isDIV_d;
    uses_rs2_d = isALUreg_d || isBranch_d || isStore_d || isMUL_d || isDIV_d;

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
  logic [31:0] id_ex_len;
  logic [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
  logic [2:0]  id_ex_funct3;
  logic [6:0]  id_ex_funct7;
  logic [31:0] id_ex_rs1_val, id_ex_rs2_val;
  logic [31:0] id_ex_Uimm, id_ex_Iimm, id_ex_Simm, id_ex_Bimm, id_ex_Jimm;
  logic        id_ex_isALUreg, id_ex_isALUimm, id_ex_isBranch, id_ex_isJALR, id_ex_isJAL;
  logic        id_ex_isAUIPC, id_ex_isLUI, id_ex_isLoad, id_ex_isStore, id_ex_isCSRRS, id_ex_isEBREAK;
  logic        id_ex_isMUL, id_ex_isDIV;

  // ---------------------- EX stage (with forwarding) ----------------------
  logic [31:0] ex_rs1, ex_rs2;

  logic ex_redirect;
  logic [31:0] ex_redirect_pc;
  logic [31:0] ex_jalr_sum;

  logic [31:0] ex_alu_in2;
  logic [31:0] ex_alu_out;

  logic ex_eq, ex_ltu, ex_lt;
  logic ex_take_branch;

  logic [31:0] ex_pc_plus_len;
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
  logic stall_div;
  logic stall_any;
  always_comb begin
    stall_load_use = 1'b0;
    stall_div = 1'b0;

    // Load-use hazard
    if (id_valid && id_ex_valid && id_ex_isLoad && (id_ex_rd != 5'd0)) begin
      if ((uses_rs1_d && (id_ex_rd == rs1_d)) || (uses_rs2_d && (id_ex_rd == rs2_d))) begin
        stall_load_use = 1'b1;
      end
    end

    // Division stall - stall when division is running OR when division instruction enters EX
    if (div_busy || (id_ex_isDIV && id_ex_valid && !div_result_valid)) begin
      stall_div = 1'b1;
    end

    stall_any = stall_load_use || stall_div;
  end

  // ---------------------- Frontend fetch gating ----------------------
  // Keep enough headroom to append the words already in flight (ROM->F2 and F2->IBUF)
  // and still leave room for another word fetch.
  assign halt_now = (!halted && id_ex_valid && id_ex_isEBREAK);
  always_comb begin
    int pending_hw;
    pending_hw = (f2_valid ? 2 : 0) + (if_valid ? 2 : 0);
    fetch_req = !halted && !halt_now && !ex_redirect &&
                ((int'(ibuf_hw_count) + pending_hw) <= (IBUF_HW_MAX - 2));
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

  // ---------------------- Division step logic ----------------------
  wire div_step_do = (div_divisor <= {31'b0, div_dividend});

  // ---------------------- EX stage logic ----------------------
  always_comb begin
    logic [4:0] shamt;
    logic is_sub;
    logic mem_byteAccess, mem_halfwordAccess;

    // Multiplication
    logic [63:0] mul_result;
    logic signed [63:0] mul_signed_result;
    logic signed [63:0] mul_mixed_result;

    shamt            = 5'b0;
    is_sub           = 1'b0;
    mem_byteAccess     = 1'b0;
    mem_halfwordAccess = 1'b0;

    // Initialize multiplication results to avoid latches
    mul_result = 64'b0;
    mul_signed_result = 64'b0;
    mul_mixed_result = 64'b0;

    // Defaults
    ex_alu_in2   = 32'b0;
    ex_alu_out   = 32'b0;

    ex_eq  = 1'b0;
    ex_ltu = 1'b0;
    ex_lt  = 1'b0;
    ex_take_branch = 1'b0;

    ex_pc_plus_len  = id_ex_pc + id_ex_len;
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
      if (id_ex_isMUL) begin
        // Multiplication logic
        unique case (id_ex_funct3)
          3'b000: mul_result = $unsigned(ex_rs1) * $unsigned(ex_rs2); // MUL
          3'b001: mul_signed_result = $signed(ex_rs1) * $signed(ex_rs2); // MULH
          3'b010: mul_mixed_result = $signed(ex_rs1) * $signed({1'b0, ex_rs2}); // MULHSU
          3'b011: mul_result = $unsigned(ex_rs1) * $unsigned(ex_rs2); // MULHU
          default: mul_result = 64'b0;
        endcase

        ex_wb_en = 1'b1;
        ex_wb_value = (id_ex_funct3 == 3'b000) ? mul_result[31:0] :
                      (id_ex_funct3 == 3'b001) ? mul_signed_result[63:32] :
                      (id_ex_funct3 == 3'b010) ? mul_mixed_result[63:32] :
                                                 mul_result[63:32];
      end else if (id_ex_isALUreg || id_ex_isALUimm) begin
        ex_wb_en    = 1'b1;
        ex_wb_value = ex_alu_out;
      end else if (id_ex_isDIV && div_result_valid) begin
        // Division result writeback
        ex_wb_en = 1'b1;
        ex_wb_value = id_ex_funct3[1] ? div_result_r : div_result_q;  // REM or DIV
      end else if (id_ex_isJAL || id_ex_isJALR) begin
        ex_wb_en    = 1'b1;
        ex_wb_value = ex_pc_plus_len;
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
    // - Only capture ROM read-data into a register (`f2_word`), then operate on that.
    instr.addr = pc_f;
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
      f2_word     <= 32'b0;
      f2_valid    <= 1'b0;
      id_valid    <= 1'b0;
      id_pc       <= 32'b0;
      id_instr    <= 32'b0;
      id_len      <= 32'd4;

      ibuf         <= '0;
      ibuf_hw_count <= '0;
      pc_i          <= 32'b0;
      drop_halfword <= 1'b0;

      id_ex_valid <= 1'b0;
      id_ex_pc    <= 32'b0;
      id_ex_instr <= 32'b0;
      id_ex_len   <= 32'd4;
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
      id_ex_isMUL    <= 1'b0;
      id_ex_isDIV    <= 1'b0;

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

      div_dividend <= 32'b0;
      div_divisor <= 63'b0;
      div_quotient <= 32'b0;
      div_quotient_msk <= 32'b0;
      div_sign <= 1'b0;
      div_busy <= 1'b0;
      div_result_q <= 32'b0;
      div_result_r <= 32'b0;
      div_result_valid <= 1'b0;

      csr_cycle   <= 64'b0;
      csr_instret <= 64'b0;
    end else begin
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

      if (!halted) begin
        logic [16*IBUF_HW_MAX-1:0] ibuf_n;
        logic [$clog2(IBUF_HW_MAX+1)-1:0] ibuf_cnt_n;
        logic [31:0] pc_i_n;
        logic drop_n;
        logic have_hw0, have_hw1;
        logic [15:0] hw0, hw1;
        logic is_rvc;
        logic [$clog2(IBUF_HW_MAX+1)-1:0] inst_hw_len;
        logic [31:0] inst32;
        rvc_exp_t exp;

        ibuf_n     = ibuf;
        ibuf_cnt_n = ibuf_hw_count;
        pc_i_n     = pc_i;
        drop_n     = drop_halfword;

        if (halt_now || ex_redirect) begin
          ibuf_n     = '0;
          ibuf_cnt_n = '0;
          pc_i_n     = ex_redirect ? ex_redirect_pc : pc_i;
          drop_n     = ex_redirect ? ex_redirect_pc[1] : 1'b0;
        end else begin
          // Append the captured 32-bit word (F2 stage). Note that instr.rdata itself is
          // only ever written into f2_word; we do not operate on instr.rdata directly.
          if (f2_valid) begin
            ibuf_n[16*ibuf_cnt_n +: 16] = f2_word[15:0];
            ibuf_n[16*(ibuf_cnt_n + 1) +: 16] = f2_word[31:16];
            ibuf_cnt_n = ibuf_cnt_n + 2;
          end

          // Align to 2-byte boundary after redirect by dropping the first halfword.
          if (drop_n && (ibuf_cnt_n != 0)) begin
            ibuf_n = ibuf_n >> 16;
            ibuf_cnt_n = ibuf_cnt_n - 1;
            drop_n = 1'b0;
          end
        end

        // Issue into ID stage when not stalling.
        if (halt_now || ex_redirect) begin
          id_valid <= 1'b0;
          id_pc    <= 32'b0;
          id_instr <= 32'h0000_0013; // NOP
          id_len   <= 32'd4;
        end else if (!stall_any) begin
          have_hw0 = (ibuf_cnt_n != 0);
          have_hw1 = (ibuf_cnt_n > 1);
          hw0      = ibuf_n[15:0];
          hw1      = ibuf_n[31:16];
          is_rvc   = have_hw0 && (hw0[1:0] != 2'b11);
          inst_hw_len = is_rvc ? 1 : 2;

          if (have_hw0 && (is_rvc || have_hw1)) begin
            if (is_rvc) begin
              exp   = rvc_expand(hw0);
              inst32 = exp.insn;
            end else begin
              inst32 = {hw1, hw0};
            end

            id_valid <= 1'b1;
            id_pc    <= pc_i_n;
            id_instr <= inst32;
            id_len   <= is_rvc ? 32'd2 : 32'd4;

            // Pop consumed halfwords and advance PC.
            ibuf_n = ibuf_n >> (16 * inst_hw_len);
            ibuf_cnt_n = ibuf_cnt_n - inst_hw_len;
            pc_i_n = pc_i_n + (is_rvc ? 32'd2 : 32'd4);
          end else begin
            id_valid <= 1'b0;
            id_pc    <= pc_i_n;
            id_instr <= 32'h0000_0013;
            id_len   <= 32'd4;
          end
        end

        ibuf         <= ibuf_n;
        ibuf_hw_count <= ibuf_cnt_n;
        pc_i          <= pc_i_n;
        drop_halfword <= drop_n;

        // Capture ROM output into a register (BRAM inference-friendly).
        if (halt_now || ex_redirect) begin
          f2_valid <= 1'b0;
          f2_word  <= 32'b0;
        end else begin
          f2_valid <= if_valid;
          if (if_valid) begin
            f2_word <= instr.rdata;
          end
        end
      end

      // Word fetch pointer and in-flight tracking.
      if (!halted && !halt_now) begin
        if (ex_redirect) begin
          pc_f     <= {ex_redirect_pc[31:2], 2'b00};
          if_pc    <= 32'b0;
          if_valid <= 1'b0;
        end else if (fetch_req) begin
          if_pc    <= pc_f;
          if_valid <= 1'b1;
          pc_f     <= pc_f + 32'd4;
        end else begin
          if_pc    <= if_pc;
          if_valid <= 1'b0;
          pc_f     <= pc_f;
        end
      end else if (!halted && halt_now) begin
        if_valid <= 1'b0;
      end

      // ID/EX update (bubble on stall/flush, but don't bubble for division stall)
      if (!halted) begin
        if (halt_now || ex_redirect || stall_load_use) begin
          id_ex_valid <= 1'b0;
        end else if (!stall_div) begin
          id_ex_valid  <= id_valid;
          id_ex_pc     <= id_pc;
          id_ex_instr  <= id_instr;
          id_ex_len    <= id_len;
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
          id_ex_isMUL    <= isMUL_d;
          id_ex_isDIV    <= isDIV_d;
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

      // Division state machine
      if (!halted) begin
        // Clear div_busy and div_result_valid on pipeline flush
        if (ex_redirect || halt_now) begin
          div_busy <= 1'b0;
          div_result_valid <= 1'b0;
        end else if (div_result_valid && (!id_ex_isDIV || !id_ex_valid)) begin
          // Clear result valid when division instruction leaves EX stage
          div_result_valid <= 1'b0;
        end

        if (!div_busy) begin
          // Start new division if division instruction is in EX stage
          if (id_ex_isDIV && id_ex_valid && !div_result_valid) begin
            // Check for division by zero (RISC-V spec: DIV/DIVU by 0 = -1, REM/REMU by 0 = dividend)
            if (ex_rs2 == 32'b0) begin
              // Division by zero - return result immediately
              div_result_q <= 32'hFFFFFFFF;  // -1 for DIV/DIVU
              div_result_r <= ex_rs1;         // dividend for REM/REMU
              div_result_valid <= 1'b1;
              div_busy <= 1'b0;
            end else begin
              // Normal division
              div_quotient_msk <= 1 << 31;
              div_busy <= 1'b1;
              div_dividend <= (~id_ex_funct3[0] & ex_rs1[31]) ? -$signed(ex_rs1) : ex_rs1;
              div_divisor <= {(~id_ex_funct3[0] & ex_rs2[31]) ? -$signed(ex_rs2) : ex_rs2, 31'b0};
              div_quotient <= 32'b0;
              div_sign <= ~id_ex_funct3[0] & (id_ex_funct3[1] ? ex_rs1[31] :
                            (ex_rs1[31] != ex_rs2[31]) & |ex_rs2);
            end
          end
        end else begin
          // Division in progress
          div_dividend <= div_step_do ? div_dividend - div_divisor[31:0] : div_dividend;
          div_divisor <= div_divisor >> 1;
          div_quotient <= div_step_do ? div_quotient | div_quotient_msk : div_quotient;
          div_quotient_msk <= div_quotient_msk >> 1;

          // On completion, save results and clear busy flag
          if (div_quotient_msk[0]) begin
            div_busy <= 1'b0;
            div_result_valid <= 1'b1;
            // Calculate final results including the last iteration
            // Quotient: accumulate all bits including the last one
            div_result_q <= div_sign ?
                            -(div_step_do ? (div_quotient | 32'd1) : div_quotient) :
                            (div_step_do ? (div_quotient | 32'd1) : div_quotient);
            div_result_r <= div_sign ?
                            -(div_step_do ? (div_dividend - div_divisor[31:0]) : div_dividend) :
                            (div_step_do ? (div_dividend - div_divisor[31:0]) : div_dividend);
          end
        end
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
