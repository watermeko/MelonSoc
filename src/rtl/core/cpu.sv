`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"
`include "../lib/rvc.sv"
`include "../util/divider.sv"
module cpu (
        input  logic clk,
        input  logic rst_n,
        input logic ext_irq,
        input logic sw_irq,
        input  logic timer_irq,
        input  logic ext_write_valid,
        input  logic [31:0] ext_write_addr,
        input  logic [3:0] ext_write_sel,
        imem_if.master instr,
        wb_if.master data
    );
    import soc_pkg::*;
    import rvc::*;

    imem_if core_instr();
    wb_if core_data();
    // ---------------------- 通用寄存器堆 ----------------------
    // Keep the architectural register file in flip-flops.  GowinSyn otherwise
    // folds the array and the ID/EX operand registers into synchronous SDPB
    // outputs.  Those outputs continue following the decode addresses while
    // the pipeline is stalled, whereas id_ex_rs{1,2}_val must hold their
    // current instruction's operands.
    logic [31:0] reg_bank [0:31] /* synthesis syn_ramstyle = "registers" */;
    integer reg_reset_idx;

    // ---------------------- 流水线结构 ----------------------
    // 本核是一个简单的顺序执行流水线，并带有支持 RVC 的取指前端。
    // 各阶段含义：
    // - IF:   pc_f -> 以 32-bit word 为粒度的取指地址（永远 4 字节对齐；用于读 ROM/BRAM）
    // - F2:   将 instr.rdata 捕获到 f2_word（对 ROM 输出打一拍；利于 BRAM 推断，避免组合反馈）
    // - IBUF: halfword(16-bit) 队列，用于拼装 16/32-bit 变长指令
    // - ID:   id_instr/id_pc/id_valid（显式寄存；避免 ROM 数据组合地反馈到自身控制/寻址）
    // - EX:   id_ex_*（执行、分支/跳转决策、地址生成、旁路/前递）
    // - MEM:  ex_mem_*（驱动数据总线）
    // - WB:   mem_wb_*（加载指令的数据在此对齐/符号扩展后再写回）

    logic halted;
    logic halt_now;

    // ---------------------- 除法器接口 ----------------------
    logic        div_start;
    logic        div_flush;
    logic        div_busy;
    logic        div_result_valid;
    logic [31:0] div_result_q;
    logic [31:0] div_result_r;

    // ---------------------- IF 阶段 ----------------------
    // MARK: IF
    logic [31:0] pc_f;
    logic        if_valid; 
    logic [31:0] if_pc;    
    logic [31:0] f2_word;
    logic        f2_valid;
    logic        if_fetch_fault, if_fetch_page_fault;
    logic        f2_fetch_fault, f2_fetch_page_fault;

    // 半字缓存，用来缓存RVC指令
    localparam int unsigned IBUF_HW_MAX = 8;
    logic [16*IBUF_HW_MAX-1:0] ibuf;
    logic [IBUF_HW_MAX-1:0] ibuf_fetch_fault;
    logic [IBUF_HW_MAX-1:0] ibuf_fetch_page_fault;
    logic [$clog2(IBUF_HW_MAX+1)-1:0] ibuf_hw_count;
    logic [31:0] pc_i;          // 将要发射到 ID 的“架构 PC”（字节地址；RVC 时 +2，否则 +4）
    logic        drop_halfword; // redirect 后若目标落在 word 内部的 2-byte 边界，丢弃一个 halfword 以对齐 IBUF
    logic        fetch_req;

    // ---------------------- ID 阶段 ----------------------
    // MARK: ID
    // PROGROM 的读数据在组合路径里不能反向影响自身控制/地址，否则无法推断为BSRAM
    logic        id_valid;
    logic [31:0] id_pc;
    logic [31:0] id_instr;
    logic [31:0] id_len;
    logic        id_illegal;
    logic [31:0] id_illegal_value;
    logic        id_fetch_fault;
    logic        id_fetch_page_fault;
    logic [31:0] id_fetch_fault_value;

    logic [31:0] instr_d;
    logic [6:0]  opcode_d;
    logic [4:0]  rs1_d, rs2_d, rd_d;
    logic [2:0]  funct3_d;
    logic [6:0]  funct7_d;

    logic [31:0] Uimm_d, Iimm_d, Simm_d, Bimm_d, Jimm_d;

    logic isALUreg_d, isALUimm_d, isBranch_d, isJALR_d, isJAL_d, isAUIPC_d, isLUI_d;
    logic isLoad_d, isStore_d;
    logic isSYSTEM_d, isMRET_d, isSRET_d, isWFI_d, isSFENCE_d, isEBREAK_d;
    logic isCSRRC_d, isCSRRW_d, isCSRRS_d, isECALL_d;
    logic isMUL_d, isDIV_d;
    logic isFENCE_d, isFENCEI_d;
    logic isAtomic_d, isLR_d, isSC_d;
    logic [3:0] amo_op_d;
    logic aq_d, rl_d;
    logic alu_reg_valid_d, alu_imm_valid_d, branch_valid_d, load_valid_d, store_valid_d;
    logic alu_reg_funct_valid_d;
    logic system_valid_d, amo_funct_valid_d, lr_encoding_d, sc_encoding_d;
        logic decoded_valid_d, illegal_d;

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
        isALUreg_d = id_valid && (opcode_d == 7'b0110011) &&
                     ((funct7_d == 7'b0000000) || (funct7_d == 7'b0100000));
        isALUimm_d = id_valid && (opcode_d == 7'b0010011);
        isBranch_d = id_valid && (opcode_d == 7'b1100011);
        isJALR_d   = id_valid && (opcode_d == 7'b1100111) && (funct3_d == 3'b000);
        isJAL_d    = id_valid && (opcode_d == 7'b1101111);
        isAUIPC_d  = id_valid && (opcode_d == 7'b0010111);
        isLUI_d    = id_valid && (opcode_d == 7'b0110111);
        isLoad_d   = id_valid && (opcode_d == 7'b0000011);
        isStore_d  = id_valid && (opcode_d == 7'b0100011);
        isSYSTEM_d = id_valid && (opcode_d == 7'b1110011);
        isFENCE_d  = id_valid && (opcode_d == 7'b0001111) && (funct3_d == 3'b000);
        isFENCEI_d = id_valid && (opcode_d == 7'b0001111) && (funct3_d == 3'b001) &&
                     (rs1_d == 5'd0) && (rd_d == 5'd0) && (instr_d[31:20] == 12'b0);

        isMUL_d = id_valid && (opcode_d == 7'b0110011) && (funct7_d == 7'b0000001) && (funct3_d[2] == 1'b0);
        isDIV_d = id_valid && (opcode_d == 7'b0110011) && (funct7_d == 7'b0000001) && (funct3_d[2] == 1'b1);

        isAtomic_d = id_valid && (opcode_d == 7'b0101111) && (funct3_d == 3'b010);
        lr_encoding_d = isAtomic_d && (instr_d[31:27] == 5'b00010);
        sc_encoding_d = isAtomic_d && (instr_d[31:27] == 5'b00011);
        isLR_d = lr_encoding_d && (rs2_d == 5'd0);
        isSC_d = sc_encoding_d;
        aq_d = isAtomic_d && instr_d[26];
        rl_d = isAtomic_d && instr_d[25];
        unique case (instr_d[31:27])
            5'b00000: amo_op_d = 4'd0; // AMOADD
            5'b00001: amo_op_d = 4'd1; // AMOSWAP
            5'b00100: amo_op_d = 4'd2; // AMOXOR
            5'b01000: amo_op_d = 4'd3; // AMOOR
            5'b01100: amo_op_d = 4'd4; // AMOAND
            5'b10000: amo_op_d = 4'd5; // AMOMIN
            5'b10100: amo_op_d = 4'd6; // AMOMAX
            5'b11000: amo_op_d = 4'd7; // AMOMINU
            5'b11100: amo_op_d = 4'd8; // AMOMAXU
            default:  amo_op_d = 4'd0;
        endcase
        amo_funct_valid_d = (instr_d[31:27] == 5'b00000) ||
                            (instr_d[31:27] == 5'b00001) ||
                            (instr_d[31:27] == 5'b00010) ||
                            (instr_d[31:27] == 5'b00011) ||
                            (instr_d[31:27] == 5'b00100) ||
                            (instr_d[31:27] == 5'b01000) ||
                            (instr_d[31:27] == 5'b01100) ||
                            (instr_d[31:27] == 5'b10000) ||
                            (instr_d[31:27] == 5'b10100) ||
                            (instr_d[31:27] == 5'b11000) ||
                            (instr_d[31:27] == 5'b11100);

        isCSRRW_d = isSYSTEM_d && ((funct3_d == 3'b001) || (funct3_d == 3'b101));
        isCSRRS_d = isSYSTEM_d && ((funct3_d == 3'b010) || (funct3_d == 3'b110));
        isCSRRC_d = isSYSTEM_d && ((funct3_d == 3'b011) || (funct3_d == 3'b111));
        isMRET_d   = isSYSTEM_d && (instr_d == 32'h3020_0073);
        isSRET_d   = isSYSTEM_d && (instr_d == 32'h1020_0073);
        isWFI_d    = isSYSTEM_d && (instr_d == 32'h1050_0073);
        isSFENCE_d = isSYSTEM_d && (funct3_d == 3'b000) &&
                     (funct7_d == 7'b0001001) && (rd_d == 5'd0);
        isEBREAK_d = isSYSTEM_d && (instr_d == 32'h0010_0073);
        isECALL_d  = isSYSTEM_d && (instr_d == 32'h0000_0073);

        alu_reg_valid_d = isALUreg_d || isMUL_d || isDIV_d;
        alu_reg_funct_valid_d = (funct3_d == 3'b000) || (funct3_d == 3'b001) ||
                                (funct3_d == 3'b010) || (funct3_d == 3'b011) ||
                                (funct3_d == 3'b100) || (funct3_d == 3'b101) ||
                                (funct3_d == 3'b110) || (funct3_d == 3'b111);
        alu_imm_valid_d = isALUimm_d &&
                          ((funct3_d == 3'b000) || (funct3_d == 3'b001) ||
                           (funct3_d == 3'b010) || (funct3_d == 3'b011) ||
                           (funct3_d == 3'b100) || (funct3_d == 3'b101) ||
                           (funct3_d == 3'b110) || (funct3_d == 3'b111));
        branch_valid_d = isBranch_d &&
                         ((funct3_d == 3'b000) || (funct3_d == 3'b001) ||
                          (funct3_d == 3'b100) || (funct3_d == 3'b101) ||
                          (funct3_d == 3'b110) || (funct3_d == 3'b111));
        load_valid_d = isLoad_d &&
                       ((funct3_d == 3'b000) || (funct3_d == 3'b001) ||
                        (funct3_d == 3'b010) || (funct3_d == 3'b100) ||
                        (funct3_d == 3'b101));
        store_valid_d = isStore_d &&
                        ((funct3_d == 3'b000) || (funct3_d == 3'b001) ||
                         (funct3_d == 3'b010));
        system_valid_d = isMRET_d || isSRET_d || isWFI_d || isSFENCE_d ||
                         isEBREAK_d || isECALL_d || isCSRRW_d || isCSRRS_d || isCSRRC_d;

        // CSR register instructions (CSRRW/CSRRS/CSRRC, funct3[2]=0) use rs1 as write value;
        // must be included in uses_rs1_d so load-use stalls fire correctly when a load
        // result feeds a CSR write (e.g. lw t0, 0(sp) followed by csrw mepc, t0).
        uses_rs1_d = isALUreg_d || isALUimm_d || isBranch_d || isJALR_d || isLoad_d || isStore_d || isMUL_d || isDIV_d
                     || isAtomic_d || (isCSRRW_d && !funct3_d[2]) || (isCSRRS_d && !funct3_d[2]) ||
                     (isCSRRC_d && !funct3_d[2]);
        uses_rs2_d = isALUreg_d || isBranch_d || isStore_d || isMUL_d || isDIV_d || (isAtomic_d && !isLR_d);

        decoded_valid_d = (alu_reg_valid_d && alu_reg_funct_valid_d) || alu_imm_valid_d || branch_valid_d ||
                          (isJALR_d || (id_valid && opcode_d == 7'b1101111)) ||
                          (id_valid && ((opcode_d == 7'b0010111) || (opcode_d == 7'b0110111))) ||
                          load_valid_d || store_valid_d || system_valid_d || isFENCE_d || isFENCEI_d ||
                          (lr_encoding_d && (rs2_d == 5'd0)) || sc_encoding_d ||
                          (isAtomic_d && amo_funct_valid_d && !lr_encoding_d && !sc_encoding_d) ||
                          sc_encoding_d;
        illegal_d = id_valid && (id_illegal || !decoded_valid_d);

        Uimm_d = {instr_d[31], instr_d[30:12], 12'b0};
        Iimm_d = {{20{instr_d[31]}}, instr_d[31:20]};
        Simm_d = {{20{instr_d[31]}}, instr_d[31:25], instr_d[11:7]};
        Bimm_d = {{20{instr_d[31]}}, instr_d[7], instr_d[30:25], instr_d[11:8], 1'b0};
        Jimm_d = {{12{instr_d[31]}}, instr_d[19:12], instr_d[20], instr_d[30:21], 1'b0};
    end

    // 寄存器回写旁路：如果当前指令的源寄存器与 WB 阶段要写回的寄存器相同，则直接使用 WB 的值
    always_comb begin
        rs1_val_d = 32'b0;
        rs2_val_d = 32'b0;

        if (rs1_d != 5'd0) begin
            rs1_val_d = (atomic_wb_valid && (atomic_wb_rd == rs1_d)) ? atomic_wb_value :
                        (wb_we && (mem_wb_rd == rs1_d)) ? wb_value : reg_bank[rs1_d];
        end

        if (rs2_d != 5'd0) begin
            rs2_val_d = (atomic_wb_valid && (atomic_wb_rd == rs2_d)) ? atomic_wb_value :
                        (wb_we && (mem_wb_rd == rs2_d)) ? wb_value : reg_bank[rs2_d];
        end
    end

    // ---------------------- ID/EX 流水寄存器 ----------------------
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
    logic        id_ex_isAUIPC, id_ex_isLUI, id_ex_isLoad, id_ex_isStore;
    logic        id_ex_isCSRRS, id_ex_isCSRRC, id_ex_isCSRRW;
    logic        id_ex_isMRET, id_ex_isSRET, id_ex_isWFI, id_ex_isSFENCE, id_ex_isEBREAK, id_ex_isECALL;
    logic        id_ex_isMUL, id_ex_isDIV;
    logic        id_ex_isFENCE, id_ex_isAtomic, id_ex_isLR, id_ex_isSC;
    logic [3:0]  id_ex_amo_op;
    logic        id_ex_aq, id_ex_rl;
    logic        id_ex_illegal;
    logic [31:0] id_ex_illegal_value;
    logic        id_ex_fetch_fault;
    logic        id_ex_fetch_page_fault;
    logic [31:0] id_ex_fetch_fault_value;

    // ---------------------- EX 阶段（带前递/旁路） ----------------------
    // MARK:EX
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
    logic        ex_misaligned;
    logic        ex_access_fault;
    logic        d_xlate_req;
    logic        d_xlate_ready;
    logic [31:0] d_phys_addr;
    logic        d_page_fault;
    logic        d_access_fault;
    logic        mmu_instr_fault;
    logic        mmu_instr_page_fault;
    logic [31:0] mmu_instr_fault_vaddr;

    always_comb begin
        ex_addr = id_ex_isAtomic ? ex_rs1 :
                  ex_rs1 + (id_ex_isStore ? id_ex_Simm : id_ex_Iimm);
        ex_misaligned = id_ex_valid &&
                        (((id_ex_isAtomic ||
                           ((id_ex_isLoad || id_ex_isStore) && (id_ex_funct3[1:0] == 2'b10))) &&
                          (ex_addr[1:0] != 2'b00)) ||
                         (((id_ex_isLoad || id_ex_isStore) && (id_ex_funct3[1:0] == 2'b01)) &&
                          ex_addr[0]));
        ex_access_fault = id_ex_valid && d_xlate_ready &&
                          (d_access_fault ||
                           (id_ex_isAtomic && !supports_atomic(d_phys_addr)) ||
                           ((id_ex_isLoad || id_ex_isStore) &&
                            !is_mapped_data_address(d_phys_addr)));
    end

    assign d_xlate_req = id_ex_valid &&
                         (id_ex_isLoad || id_ex_isStore || id_ex_isAtomic) &&
                         !ex_misaligned;

    // ---------------------- EX/MEM 流水寄存器 ----------------------
    logic        ex_mem_valid;
    logic [4:0]  ex_mem_rd;
    logic        ex_mem_isLoad, ex_mem_isStore;
    logic        ex_mem_isAtomic, ex_mem_isLR, ex_mem_isSC;
    logic [2:0]  ex_mem_funct3;
    logic [3:0]  ex_mem_amo_op;
    logic        ex_mem_aq, ex_mem_rl;
    logic [31:0] ex_mem_rs2_value;
    logic [31:0] ex_mem_addr;
    logic [31:0] ex_mem_store_wdata;
    logic [3:0]  ex_mem_store_wmask;
    logic        ex_mem_wb_en;
    logic [31:0] ex_mem_wb_value;

    // ---------------------- MEM/WB 流水寄存器 ----------------------
    logic        mem_wb_valid;
    logic [4:0]  mem_wb_rd;
    logic        mem_wb_isLoad;
    logic [2:0]  mem_wb_funct3;
    logic [1:0]  mem_wb_addr_low;
    logic [31:0] mem_wb_load_word;
    logic        mem_wb_wb_en;
    logic [31:0] mem_wb_wb_value;

    // ---------------------- 写回（WB）阶段 ----------------------
    // MARK:WB
    logic [31:0] wb_load_data;
    logic [31:0] wb_value;
    logic        wb_we;
    logic        wb_retire;

    function automatic logic [31:0] arithmetic_shift_right(
        input logic [31:0] value,
        input logic [4:0] amount
    );
        logic [31:0] sign_fill;
        begin
            sign_fill = {32{value[31]}} & ~(32'hFFFF_FFFF >> amount);
            return (value >> amount) | sign_fill;
        end
    endfunction

    function automatic logic [31:0] format_load_data(
        input logic [31:0] word,
        input logic [2:0] funct3,
        input logic [1:0] addr_low
    );
        logic [15:0] half_value;
        logic [7:0] byte_value;
        logic sign_bit;
        begin
            half_value = addr_low[1] ? word[31:16] : word[15:0];
            byte_value = addr_low[0] ? half_value[15:8] : half_value[7:0];
            sign_bit = ~funct3[2] &
                       ((funct3[1:0] == 2'b00) ? byte_value[7] :
                                                         half_value[15]);
            case (funct3[1:0])
                2'b00: format_load_data = {{24{sign_bit}}, byte_value};
                2'b01: format_load_data = {{16{sign_bit}}, half_value};
                default: format_load_data = word;
            endcase
        end
    endfunction

    // ---------------------- 冒险检测 ----------------------
    // 这里处理的数据相关：
    // - 大多数 ALU 相关由 EX 阶段前递解决。
    // - Load-use 相关必须停顿，因为加载指令的数据要到 WB 才可用（此实现没有 MEM 级旁路）。
    // - 除法是多周期迭代单元，流水线会一直停住直到 div_result_valid。
    logic stall_load_use;
    logic stall_div;
    logic stall_mem;
    logic mem_started;
    logic mem_req;
    logic stall_atomic;
    logic stall_mmu;
    logic stall_any;

    assign mem_req = ex_mem_valid && (ex_mem_isLoad || ex_mem_isStore);

    typedef enum logic [2:0] {
        ATOMIC_IDLE,
        ATOMIC_LR_READ,
        ATOMIC_LR_CAPTURE,
        ATOMIC_SC_WRITE,
        ATOMIC_AMO_READ,
        ATOMIC_AMO_CAPTURE,
        ATOMIC_AMO_WRITE,
        ATOMIC_COMPLETE
    } atomic_state_t;

    atomic_state_t atomic_state;
    logic          atomic_started;
    logic [31:0]   atomic_addr;
    logic [31:0]   atomic_store_data;
    logic [31:0]   atomic_old_value;
    logic [31:0]   atomic_new_value;
    logic [31:0]   atomic_result;
    logic [4:0]    atomic_rd;
    logic [3:0]    atomic_op;
    logic          atomic_is_lr;
    logic          atomic_is_sc;
    logic          reservation_valid;
    logic [29:0]   reservation_word_addr;
    logic          atomic_complete;
    logic          atomic_wb_valid;
    logic [4:0]    atomic_wb_rd;
    logic [31:0]   atomic_wb_value;

    assign atomic_complete = (atomic_state == ATOMIC_COMPLETE);

    function automatic logic [31:0] amo_compute(
        input logic [3:0] op,
        input logic [31:0] old_value,
        input logic [31:0] rhs
    );
        logic signed [31:0] old_signed;
        logic signed [31:0] rhs_signed;
        begin
            old_signed = old_value;
            rhs_signed = rhs;
            unique case (op)
                4'd0: amo_compute = old_value + rhs;
                4'd1: amo_compute = rhs;
                4'd2: amo_compute = old_value ^ rhs;
                4'd3: amo_compute = old_value | rhs;
                4'd4: amo_compute = old_value & rhs;
                4'd5: amo_compute = (old_signed < rhs_signed) ? old_value : rhs;
                4'd6: amo_compute = (old_signed > rhs_signed) ? old_value : rhs;
                4'd7: amo_compute = (old_value < rhs) ? old_value : rhs;
                4'd8: amo_compute = (old_value > rhs) ? old_value : rhs;
                default: amo_compute = old_value;
            endcase
        end
    endfunction
    always_comb begin
        stall_load_use = 1'b0;
        stall_div = 1'b0;
        stall_mem = 1'b0;
        // 当前一条指令是 load，且当前指令使用了它加载到的寄存器时，停顿流水线
        if (id_valid && id_ex_valid && id_ex_isLoad && (id_ex_rd != 5'd0)) begin
            if ((uses_rs1_d && (id_ex_rd == rs1_d)) || (uses_rs2_d && (id_ex_rd == rs2_d))) begin
                stall_load_use = 1'b1;
            end
        end
        if (div_busy || (id_ex_isDIV && id_ex_valid && !div_result_valid)) begin
            stall_div = 1'b1;
        end

        stall_mem = mem_req && (!mem_started || !core_data.ack);
        stall_atomic = (atomic_state != ATOMIC_IDLE) || (ex_mem_valid && ex_mem_isAtomic);
        stall_mmu = d_xlate_req && !d_xlate_ready;
        stall_any = stall_load_use || stall_div || stall_mem || stall_atomic || stall_mmu;
    end

    // ---------------------- 前端取指节流 ----------------------
    assign halt_now = 1'b0;
    always_comb begin
        int pending_hw;
        pending_hw = (f2_valid ? 2 : 0) + (if_valid ? 2 : 0);
        fetch_req = !halted && !halt_now && !ex_redirect &&
                  ((int'(ibuf_hw_count) + pending_hw) <= (IBUF_HW_MAX - 2));
    end

    // ---------------------- 前递/旁路选择 ----------------------
    // EX 阶段前递：
    // - 优先从 EX/MEM 前递 EX 级就已产生的结果（ALU/MUL/JAL 等）。Load 被排除，因为数据更晚才返回。
    // - 否则从 MEM/WB 前递最终写回值。
    logic ex_mem_fwd_en;
    logic [31:0] wb_fwd_value;
    always_comb begin
        ex_mem_fwd_en = ex_mem_valid && ex_mem_wb_en && !ex_mem_isLoad && (ex_mem_rd != 5'd0);
        wb_fwd_value  = wb_value;

        ex_rs1 = id_ex_rs1_val;
        ex_rs2 = id_ex_rs2_val;

        if (atomic_wb_valid && (atomic_wb_rd == id_ex_rs1)) begin
            ex_rs1 = atomic_wb_value;
        end
        else if (ex_mem_fwd_en && (ex_mem_rd == id_ex_rs1)) begin
            ex_rs1 = ex_mem_wb_value;
        end
        else if (mem_wb_valid && mem_wb_wb_en && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1)) begin
            ex_rs1 = wb_fwd_value;
        end

        if (atomic_wb_valid && (atomic_wb_rd == id_ex_rs2)) begin
            ex_rs2 = atomic_wb_value;
        end
        else if (ex_mem_fwd_en && (ex_mem_rd == id_ex_rs2)) begin
            ex_rs2 = ex_mem_wb_value;
        end
        else if (mem_wb_valid && mem_wb_wb_en && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2)) begin
            ex_rs2 = wb_fwd_value;
        end
    end

    // ---------------------- CSR/特权控制 ----------------------
    logic [11:0] ex_csr_addr;
    logic csr_valid;
    logic csr_illegal;
    logic xret_illegal;
    logic ex_fire;
    logic priv_trap_taken;
    logic priv_return_taken;
    logic priv_redirect_valid;
    logic [31:0] priv_redirect_pc;
    logic [1:0] current_priv;
    logic [31:0] current_mstatus;
    logic [31:0] current_satp;
    logic [31:0] irq_pending;
    logic retire_pulse;

    assign ex_csr_addr = id_ex_instr[31:20];
    assign csr_valid = id_ex_isCSRRS || id_ex_isCSRRC || id_ex_isCSRRW;
    assign ex_fire = id_ex_valid && !halted && !stall_mem && !stall_atomic &&
                     !stall_div && !stall_mmu;
    assign irq_pending = {20'b0, ext_irq, 3'b0, timer_irq, 3'b0, sw_irq, 3'b0};

    logic [31:0] ex_csr_wdata;
    logic [31:0] ex_csr_op_a;
    logic        ex_csr_we;
    // funct3[2] 为 1 时，使用的是 5-bit 无符号立即数 (zimm = rs1_d)
    assign ex_csr_op_a = id_ex_funct3[2] ? {27'b0, id_ex_rs1} : ex_rs1;
    always_comb begin
        case (id_ex_funct3[1:0])
            2'b01: ex_csr_wdata = ex_csr_op_a;                 // CSRRW 直接写入
            2'b10: ex_csr_wdata = ex_csr_rdata | ex_csr_op_a;  // CSRRS 按位置 1
            2'b11: ex_csr_wdata = ex_csr_rdata & ~ex_csr_op_a; // CSRRC 按位清 0
            default: ex_csr_wdata = ex_csr_op_a;
        endcase
    end

    always_comb begin
        ex_csr_we = 1'b0;
        if (ex_fire) begin
            if (id_ex_isCSRRW) begin
                ex_csr_we = 1'b1;
            end else if ((id_ex_isCSRRS || id_ex_isCSRRC) && (id_ex_rs1 != 5'd0)) begin
                // RISC-V 规定：对于 RS 和 RC，如果 rs1（或 zimm）为 0，则是纯读操作
                ex_csr_we = 1'b1; 
            end
        end
    end

    // ---------------------- 同步异常判断 ----------------------
    logic exception_req;
    logic [31:0] exception_cause;
    logic [31:0] exception_value;

    always_comb begin
        exception_req = 1'b0;
        exception_cause = 32'b0;
        exception_value = 32'b0;

        if (id_ex_valid && id_ex_fetch_fault && (current_priv != 2'b11) &&
            !stall_atomic) begin
            exception_req = 1'b1;
            exception_cause = id_ex_fetch_page_fault ? 32'd12 : 32'd1;
            exception_value = id_ex_fetch_fault_value;
        end

        if (!exception_req && id_ex_valid && id_ex_illegal && !stall_atomic) begin
            exception_req = 1'b1;
            exception_cause = 32'd2;
            exception_value = id_ex_illegal_value;
        end

        if (!exception_req && id_ex_valid && (csr_illegal || xret_illegal)) begin
            exception_req = 1'b1;
            exception_cause = 32'd2;
            exception_value = id_ex_instr;
        end

        if (!exception_req && id_ex_valid && ex_misaligned && !stall_atomic) begin
            exception_req = 1'b1;
            exception_cause = (id_ex_isLoad || id_ex_isLR) ? 32'd4 : 32'd6;
            exception_value = ex_addr;
        end

        if (!exception_req && id_ex_valid && d_xlate_ready && d_page_fault) begin
            exception_req = 1'b1;
            exception_cause = (id_ex_isLoad || id_ex_isLR) ? 32'd13 : 32'd15;
            exception_value = ex_addr;
        end

        if (!exception_req && id_ex_valid && ex_access_fault && !stall_atomic) begin
            exception_req = 1'b1;
            exception_cause = (id_ex_isLoad || id_ex_isLR) ? 32'd5 : 32'd7;
            exception_value = ex_addr;
        end

        if (!exception_req && id_ex_valid && !stall_mem && !stall_atomic) begin
            if (id_ex_isECALL) begin
                exception_req = 1'b1;
                unique case (current_priv)
                    2'b00: exception_cause = 32'd8;
                    2'b01: exception_cause = 32'd9;
                    default: exception_cause = 32'd11;
                endcase
            end else if (id_ex_isEBREAK) begin
                exception_req = 1'b1;
                exception_cause = 32'd3;
            end
        end
    end

    priv_csr u_priv_csr (
        .clk(clk),
        .rst_n(rst_n),
        .irq_pending_i(irq_pending),
        .ex_valid_i(id_ex_valid),
        .ex_fire_i(ex_fire),
        .ex_pc_i(id_ex_pc),
        .csr_valid_i(csr_valid),
        .csr_addr_i(ex_csr_addr),
        .csr_write_i(ex_csr_we),
        .csr_wdata_i(ex_csr_wdata),
        .csr_rdata_o(ex_csr_rdata),
        .csr_illegal_o(csr_illegal),
        .exception_valid_i(exception_req),
        .exception_cause_i(exception_cause),
        .exception_tval_i(exception_value),
        .mret_i(id_ex_isMRET),
        .sret_i(id_ex_isSRET),
        .sfence_vma_i(id_ex_isSFENCE),
        .wfi_i(id_ex_isWFI),
        .xret_illegal_o(xret_illegal),
        .retire_i(retire_pulse),
        .trap_taken_o(priv_trap_taken),
        .return_taken_o(priv_return_taken),
        .redirect_valid_o(priv_redirect_valid),
        .redirect_pc_o(priv_redirect_pc),
        .privilege_o(current_priv),
        .mstatus_o(current_mstatus),
        .satp_o(current_satp)
    );

    // Atomic operations use one held context and two bus sub-transactions.
    // The pipeline remains frozen until the complete operation can retire.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            atomic_state <= ATOMIC_IDLE;
            atomic_started <= 1'b0;
            atomic_addr <= 32'b0;
            atomic_store_data <= 32'b0;
            atomic_old_value <= 32'b0;
            atomic_new_value <= 32'b0;
            atomic_result <= 32'b0;
            atomic_rd <= 5'b0;
            atomic_op <= 4'b0;
            atomic_is_lr <= 1'b0;
            atomic_is_sc <= 1'b0;
            reservation_valid <= 1'b0;
            reservation_word_addr <= 30'b0;
            atomic_wb_valid <= 1'b0;
            atomic_wb_rd <= 5'b0;
            atomic_wb_value <= 32'b0;
        end
        else begin
            atomic_wb_valid <= (atomic_state == ATOMIC_COMPLETE) && (atomic_rd != 5'd0);
            if (ext_write_valid && reservation_valid &&
                (ext_write_addr[31:2] == reservation_word_addr) &&
                (ext_write_sel != 4'b0000)) begin
                reservation_valid <= 1'b0;
            end

            if ((atomic_state == ATOMIC_IDLE) && ex_mem_valid && ex_mem_isAtomic) begin
                atomic_addr       <= ex_mem_addr;
                atomic_store_data <= ex_mem_rs2_value;
                atomic_rd         <= ex_mem_rd;
                atomic_op         <= ex_mem_amo_op;
                atomic_is_lr      <= ex_mem_isLR;
                atomic_is_sc      <= ex_mem_isSC;
                atomic_started   <= 1'b0;

                if (ex_mem_isSC &&
                    !(reservation_valid && (reservation_word_addr == ex_mem_addr[31:2]))) begin
                    atomic_result <= 32'd1;
                    atomic_state <= ATOMIC_COMPLETE;
                    reservation_valid <= 1'b0;
                end
                else if (ex_mem_isLR) begin
                    atomic_state <= ATOMIC_LR_READ;
                end
                else if (ex_mem_isSC) begin
                    atomic_state <= ATOMIC_SC_WRITE;
                end
                else begin
                    atomic_state <= ATOMIC_AMO_READ;
                end
            end
            else begin
                unique case (atomic_state)
                    ATOMIC_LR_READ: begin
                        if (!atomic_started) begin
                            atomic_started <= 1'b1;
                        end
                        else if (core_data.ack) begin
                            atomic_started <= 1'b0;
                            atomic_state <= ATOMIC_LR_CAPTURE;
                        end
                    end
                    ATOMIC_LR_CAPTURE: begin
                        atomic_old_value <= core_data.dat_r;
                        atomic_result <= core_data.dat_r;
                        reservation_valid <= 1'b1;
                        reservation_word_addr <= atomic_addr[31:2];
                        atomic_state <= ATOMIC_COMPLETE;
                    end
                    ATOMIC_SC_WRITE: begin
                        if (!atomic_started) begin
                            atomic_started <= 1'b1;
                        end
                        else if (core_data.ack) begin
                            atomic_result <= 32'd0;
                            atomic_started <= 1'b0;
                             reservation_valid <= 1'b0;
                             atomic_state <= ATOMIC_COMPLETE;
                         end
                     end
                    ATOMIC_AMO_READ: begin
                        if (!atomic_started) begin
                            atomic_started <= 1'b1;
                        end
                        else if (core_data.ack) begin
                            atomic_started <= 1'b0;
                            atomic_state <= ATOMIC_AMO_CAPTURE;
                        end
                    end
                    ATOMIC_AMO_CAPTURE: begin
                        atomic_old_value <= core_data.dat_r;
                        atomic_new_value <= amo_compute(atomic_op, core_data.dat_r, atomic_store_data);
                        atomic_result <= core_data.dat_r;
                        reservation_valid <= 1'b0;
                        atomic_state <= ATOMIC_AMO_WRITE;
                    end
                    ATOMIC_AMO_WRITE: begin
                        if (!atomic_started) begin
                            atomic_started <= 1'b1;
                        end
                        else if (core_data.ack) begin
                            atomic_started <= 1'b0;
                            reservation_valid <= 1'b0;
                            atomic_state <= ATOMIC_COMPLETE;
                        end
                    end
                    ATOMIC_COMPLETE: begin
                        atomic_state <= ATOMIC_IDLE;
                        atomic_wb_rd <= atomic_rd;
                        atomic_wb_value <= atomic_result;
                    end
                    default: begin
                        atomic_state <= ATOMIC_IDLE;
                        atomic_started <= 1'b0;
                    end
                endcase
            end

            if (ex_mem_valid && ex_mem_isStore && core_data.ack) begin
                reservation_valid <= 1'b0;
            end
            if (priv_trap_taken || priv_return_taken || halt_now) begin
                reservation_valid <= 1'b0;
            end
        end
    end

    // ---------------------- EX 阶段组合逻辑 ----------------------
    always_comb begin
        logic [4:0] shamt;
        logic is_sub;
        logic mem_byteAccess, mem_halfwordAccess;

        logic [63:0] mul_result;
        logic [63:0] mul_signed_result;
        logic [63:0] mul_mixed_result;
        logic [63:0] op1_unsigned, op2_unsigned;
        logic signed [63:0] op1_signed, op2_signed, op2_mixed;

        shamt            = 5'b0;
        is_sub           = 1'b0;
        mem_byteAccess     = 1'b0;
        mem_halfwordAccess = 1'b0;

        mul_result = 64'b0;
        mul_signed_result = 64'b0;
        mul_mixed_result = 64'b0;
        op1_unsigned = 64'b0;
        op2_unsigned = 64'b0;
        op1_signed = 64'b0;
        op2_signed = 64'b0;
        op2_mixed = 64'b0;

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

        ex_store_wdata = 32'b0;
        ex_store_wmask = 4'b0000;

        ex_wb_en    = 1'b0;
        ex_wb_value = 32'b0;

        ex_redirect    = 1'b0;
        ex_redirect_pc = 32'b0;
        ex_jalr_sum    = 32'b0;

        if (id_ex_isALUreg || id_ex_isALUimm) begin
            shamt  = id_ex_isALUreg ? ex_rs2[4:0] : id_ex_instr[24:20];
            is_sub = id_ex_isALUreg && id_ex_funct7[5];
            ex_alu_in2 = id_ex_isALUreg ? ex_rs2 : id_ex_Iimm;

            ex_eq  = (ex_rs1 == ex_alu_in2);
            ex_ltu = (ex_rs1 < ex_alu_in2);
            ex_lt  = ($signed(ex_rs1) < $signed(ex_alu_in2));

            unique case (id_ex_funct3)
                       3'b000:
                           ex_alu_out = is_sub ? (ex_rs1 - ex_alu_in2) : (ex_rs1 + ex_alu_in2);
                       3'b001:
                           ex_alu_out = ex_rs1 << shamt;
                       3'b010:
                           ex_alu_out = {31'b0, ex_lt};
                       3'b011:
                           ex_alu_out = {31'b0, ex_ltu};
                       3'b100:
                           ex_alu_out = (ex_rs1 ^ ex_alu_in2);
                       3'b101:
                           ex_alu_out = id_ex_funct7[5] ? arithmetic_shift_right(ex_rs1, shamt) :
                                                        (ex_rs1 >> shamt);
                       3'b110:
                           ex_alu_out = (ex_rs1 | ex_alu_in2);
                       3'b111:
                           ex_alu_out = (ex_rs1 & ex_alu_in2);
                       default:
                           ex_alu_out = 32'b0;
                   endcase
               end

               if (id_ex_isBranch) begin
                   ex_eq  = (ex_rs1 == ex_rs2);
                   ex_ltu = (ex_rs1 < ex_rs2);
                   ex_lt  = ($signed(ex_rs1) < $signed(ex_rs2));

                   unique case (id_ex_funct3)
                              3'b000:
                                  ex_take_branch = ex_eq;
                              3'b001:
                                  ex_take_branch = ~ex_eq;
                              3'b100:
                                  ex_take_branch = ex_lt;
                              3'b101:
                                  ex_take_branch = ~ex_lt;
                              3'b110:
                                  ex_take_branch = ex_ltu;
                              3'b111:
                                  ex_take_branch = ~ex_ltu;
                              default:
                                  ex_take_branch = 1'b0;
                          endcase
                      end

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

                      if (id_ex_valid) begin
                          if (id_ex_isMUL) begin
                              op1_unsigned = {32'b0, ex_rs1};
                              op2_unsigned = {32'b0, ex_rs2};
                              op1_signed = {{32{ex_rs1[31]}}, ex_rs1};
                              op2_signed = {{32{ex_rs2[31]}}, ex_rs2};
                              op2_mixed = {32'b0, ex_rs2};

                              mul_result = op1_unsigned * op2_unsigned;
                              mul_signed_result = op1_signed * op2_signed;
                              mul_mixed_result = op1_signed * op2_mixed;

                              ex_wb_en = 1'b1;
                              ex_wb_value = (id_ex_funct3 == 3'b000) ? mul_result[31:0] :
                                          (id_ex_funct3 == 3'b001) ? mul_signed_result[63:32] :
                                          (id_ex_funct3 == 3'b010) ? mul_mixed_result[63:32] :
                                          mul_result[63:32];
                          end
                          else if (id_ex_isALUreg || id_ex_isALUimm) begin
                              ex_wb_en    = 1'b1;
                              ex_wb_value = ex_alu_out;
                          end
                          else if (id_ex_isDIV && div_result_valid) begin
                              ex_wb_en = 1'b1;
                              ex_wb_value = id_ex_funct3[1] ? div_result_r : div_result_q; 
                          end
                          else if (id_ex_isJAL || id_ex_isJALR) begin
                              ex_wb_en    = 1'b1;
                              ex_wb_value = ex_pc_plus_len;
                          end
                          else if (id_ex_isLUI) begin
                              ex_wb_en    = 1'b1;
                              ex_wb_value = id_ex_Uimm;
                          end
                          else if (id_ex_isAUIPC) begin
                              ex_wb_en    = 1'b1;
                              ex_wb_value = ex_pc_plus_uimm;
                          end
                          else if (id_ex_isCSRRS || id_ex_isCSRRC || id_ex_isCSRRW) begin
                              ex_wb_en    = 1'b1;
                              ex_wb_value = ex_csr_rdata;
                          end
                           else if (id_ex_isLoad) begin
                               ex_wb_en    = 1'b1;
                               ex_wb_value = 32'b0;
                           end
                      end

                      ex_jalr_sum = ex_rs1 + id_ex_Iimm;

                      ex_redirect = 1'b0;
                      ex_redirect_pc = 32'b0;

                      // Trap
                      if (priv_redirect_valid) begin
                          ex_redirect = 1'b1;
                          ex_redirect_pc = priv_redirect_pc;

                          ex_wb_en = 1'b0;
                          ex_store_wmask = 4'b0000;
                      end
                      else if (id_ex_valid) begin
                          if (id_ex_isSFENCE && !xret_illegal) begin
                              ex_redirect = 1'b1;
                              ex_redirect_pc = ex_pc_plus_len;
                          end else if (id_ex_isBranch && ex_take_branch) begin
                              ex_redirect = 1'b1;
                              ex_redirect_pc = ex_pc_plus_bimm;
                          end else if (id_ex_isJALR) begin
                              ex_redirect = 1'b1;
                              ex_redirect_pc = { ex_jalr_sum[31:1], 1'b0 };
                          end else if (id_ex_isJAL) begin
                              ex_redirect = 1'b1;
                              ex_redirect_pc = ex_pc_plus_jimm;
                          end
                      end

                       if (stall_mem || stall_atomic || stall_mmu) begin
                          ex_redirect = 1'b0;
                          ex_redirect_pc = 32'b0;
                          ex_wb_en = 1'b0;
                          ex_store_wmask = 4'b0000;
                      end
    end

    // ---------------------- WB 阶段加载数据格式化 ----------------------
    always_comb begin
        wb_load_data = format_load_data(mem_wb_load_word,
                                        mem_wb_funct3,
                                        mem_wb_addr_low);
    end

    always_comb begin
        wb_value = mem_wb_isLoad ? wb_load_data : mem_wb_wb_value;
        wb_we    = mem_wb_valid && mem_wb_wb_en && (mem_wb_rd != 5'd0) && !atomic_complete;
        wb_retire = mem_wb_valid && !stall_mem && !halted;
    end

    assign retire_pulse = wb_retire || atomic_complete;

    // ---------------------- 总线驱动 ----------------------
    always_comb begin
        core_instr.addr = pc_f;
        core_instr.ren  = fetch_req;
        core_instr.flush = ex_redirect;

        core_data.adr   = (atomic_state != ATOMIC_IDLE) ? atomic_addr : ex_mem_addr;
        core_data.dat_w = (atomic_state != ATOMIC_IDLE) ?
                     ((atomic_state == ATOMIC_SC_WRITE || atomic_state == ATOMIC_AMO_WRITE) ?
                      ((atomic_state == ATOMIC_SC_WRITE) ? atomic_store_data : atomic_new_value) : 32'b0) :
                     ex_mem_store_wdata;
        core_data.sel   = (atomic_state != ATOMIC_IDLE) ? 4'b1111 :
                     ((!halted && ex_mem_valid && ex_mem_isStore) ? ex_mem_store_wmask : 4'b1111);
        core_data.we    = (atomic_state == ATOMIC_SC_WRITE) || (atomic_state == ATOMIC_AMO_WRITE) ||
                     (!halted && ex_mem_valid && ex_mem_isStore && !ex_mem_isAtomic);
        core_data.cyc   = !halted && ((atomic_state != ATOMIC_IDLE &&
                                  (atomic_state == ATOMIC_LR_READ || atomic_state == ATOMIC_SC_WRITE ||
                                   atomic_state == ATOMIC_AMO_READ || atomic_state == ATOMIC_AMO_WRITE)) || mem_req);
        core_data.stb   = core_data.cyc && ((atomic_state != ATOMIC_IDLE) ?
                                  atomic_started : mem_started);
        core_data.lock  = (atomic_state != ATOMIC_IDLE) &&
                     ((atomic_state == ATOMIC_LR_READ) || (atomic_state == ATOMIC_LR_CAPTURE) ||
                      (atomic_state == ATOMIC_SC_WRITE) || (atomic_state == ATOMIC_AMO_READ) ||
                      (atomic_state == ATOMIC_AMO_CAPTURE) || (atomic_state == ATOMIC_AMO_WRITE));
    end

    sv32_mmu u_mmu (
        .clk(clk),
        .rst_n(rst_n),
        .satp_i(current_satp),
        .mstatus_i(current_mstatus),
        .privilege_i(current_priv),
        .sfence_vma_i(ex_fire && id_ex_isSFENCE && !xret_illegal),
        .frontend_flush_i(ex_redirect),
        .core_instr(core_instr),
        .phys_instr(instr),
        .d_req_valid_i(d_xlate_req),
        .d_vaddr_i(ex_addr),
        .d_store_i(id_ex_isStore || id_ex_isSC ||
                   (id_ex_isAtomic && !id_ex_isLR)),
        .d_req_ready_o(d_xlate_ready),
        .d_paddr_o(d_phys_addr),
        .d_page_fault_o(d_page_fault),
        .d_access_fault_o(d_access_fault),
        .instr_fault_o(mmu_instr_fault),
        .instr_page_fault_o(mmu_instr_page_fault),
        .instr_fault_vaddr_o(mmu_instr_fault_vaddr),
        .core_data(core_data),
        .phys_data(data)
    );

    // ---------------------- 时序逻辑 ----------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            halted <= 1'b0;

            for (reg_reset_idx = 0; reg_reset_idx < 32; reg_reset_idx = reg_reset_idx + 1)
                reg_bank[reg_reset_idx] <= 32'b0;

            {pc_f, if_valid, if_pc, f2_word, f2_valid,
             if_fetch_fault, if_fetch_page_fault,
             f2_fetch_fault, f2_fetch_page_fault} <= '0;
            {id_valid, id_pc, id_instr, id_illegal, id_illegal_value,
             id_fetch_fault, id_fetch_page_fault, id_fetch_fault_value} <= '0;

            {ibuf, ibuf_fetch_fault, ibuf_fetch_page_fault,
             ibuf_hw_count, pc_i, drop_halfword} <= '0;

            { id_ex_valid, id_ex_pc, id_ex_instr,
              id_ex_rs1, id_ex_rs2, id_ex_rd,
              id_ex_funct3, id_ex_funct7,
              id_ex_rs1_val, id_ex_rs2_val,
              id_ex_Uimm, id_ex_Iimm, id_ex_Simm, id_ex_Bimm, id_ex_Jimm,
              id_ex_isALUreg, id_ex_isALUimm, id_ex_isBranch, id_ex_isJALR, id_ex_isJAL,
              id_ex_isAUIPC, id_ex_isLUI, id_ex_isLoad, id_ex_isStore,
              id_ex_isCSRRS, id_ex_isCSRRC, id_ex_isCSRRW,
              id_ex_isMRET, id_ex_isSRET, id_ex_isWFI, id_ex_isSFENCE,
              id_ex_isEBREAK, id_ex_isECALL,
               id_ex_isMUL, id_ex_isDIV, id_ex_isFENCE, id_ex_isAtomic, id_ex_isLR, id_ex_isSC,
               id_ex_amo_op, id_ex_aq, id_ex_rl, id_ex_illegal, id_ex_illegal_value,
               id_ex_fetch_fault, id_ex_fetch_page_fault, id_ex_fetch_fault_value
             } <= '0;

             { ex_mem_valid, ex_mem_rd, ex_mem_isLoad, ex_mem_isStore, ex_mem_isAtomic, ex_mem_isLR, ex_mem_isSC,
               ex_mem_funct3, ex_mem_amo_op, ex_mem_aq, ex_mem_rl, ex_mem_rs2_value,
               ex_mem_addr, ex_mem_store_wdata, ex_mem_store_wmask, ex_mem_wb_en, ex_mem_wb_value
             } <= '0;

            { mem_wb_valid, mem_wb_rd, mem_wb_isLoad, mem_wb_funct3, mem_wb_addr_low,
              mem_wb_load_word,
              mem_wb_wb_en, mem_wb_wb_value
            } <= '0;
            mem_started <= 1'b0;
            id_len    <= 32'd4;
            id_ex_len <= 32'd4;
        end
        else begin
            if (!halted) begin
                if (wb_we)
                    reg_bank[mem_wb_rd] <= wb_value;
            end

            if (halt_now) begin
                halted <= 1'b1;
            end

            if (!halted) begin
                logic [16*IBUF_HW_MAX-1:0] ibuf_n;
                logic [IBUF_HW_MAX-1:0] ibuf_fault_n;
                logic [IBUF_HW_MAX-1:0] ibuf_page_fault_n;
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
                ibuf_fault_n = ibuf_fetch_fault;
                ibuf_page_fault_n = ibuf_fetch_page_fault;
                ibuf_cnt_n = ibuf_hw_count;
                pc_i_n     = pc_i;
                drop_n     = drop_halfword;

                if (halt_now || ex_redirect) begin
                    ibuf_n     = '0;
                    ibuf_fault_n = '0;
                    ibuf_page_fault_n = '0;
                    ibuf_cnt_n = '0;
                    pc_i_n     = ex_redirect ? ex_redirect_pc : pc_i;
                    drop_n     = ex_redirect ? ex_redirect_pc[1] : 1'b0;
                end
                else begin
                    if (f2_valid) begin
                        ibuf_n[16*ibuf_cnt_n +: 16] = f2_word[15:0];
                        ibuf_n[16*(ibuf_cnt_n + 1) +: 16] = f2_word[31:16];
                        ibuf_fault_n[int'(ibuf_cnt_n) +: 2] = {2{f2_fetch_fault}};
                        ibuf_page_fault_n[int'(ibuf_cnt_n) +: 2] = {2{f2_fetch_page_fault}};
                        ibuf_cnt_n = ibuf_cnt_n + 2;
                    end

                    // redirect 后若目标落在 word 内部（2-byte 对齐但非 4-byte），丢弃一个 halfword 以对齐到正确的指令边界。
                    if (drop_n && (ibuf_cnt_n != 0)) begin
                        ibuf_n = ibuf_n >> 16;
                        ibuf_fault_n = ibuf_fault_n >> 1;
                        ibuf_page_fault_n = ibuf_page_fault_n >> 1;
                        ibuf_cnt_n = ibuf_cnt_n - 1;
                        drop_n = 1'b0;
                    end
                end

                if (halt_now || ex_redirect) begin
                    id_valid <= 1'b0;
                    id_pc    <= 32'b0;
                    id_instr <= 32'h0000_0013; // NOP
                    id_len   <= 32'd4;
                    id_fetch_fault <= 1'b0;
                    id_fetch_page_fault <= 1'b0;
                    id_fetch_fault_value <= 32'b0;
                end
                else if (!stall_any) begin
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
                        end
                        else begin
                            inst32 = {hw1, hw0};
                        end

                        id_valid <= 1'b1;
                        id_pc    <= pc_i_n;
                        id_instr <= inst32;
                        id_len   <= is_rvc ? 32'd2 : 32'd4;
                        id_illegal <= is_rvc && exp.illegal;
                        id_illegal_value <= is_rvc ? {16'b0, hw0} : inst32;
                        id_fetch_fault <= ibuf_fault_n[0] ||
                                          (!is_rvc && ibuf_fault_n[1]);
                        id_fetch_page_fault <= ibuf_fault_n[0] ?
                                               ibuf_page_fault_n[0] :
                                               ibuf_page_fault_n[1];
                        id_fetch_fault_value <= ibuf_fault_n[0] ? pc_i_n :
                                                ((!is_rvc && ibuf_fault_n[1]) ?
                                                 (pc_i_n + 32'd2) : 32'b0);

                        ibuf_n = ibuf_n >> (16 * inst_hw_len);
                        ibuf_fault_n = ibuf_fault_n >> inst_hw_len;
                        ibuf_page_fault_n = ibuf_page_fault_n >> inst_hw_len;
                        ibuf_cnt_n = ibuf_cnt_n - inst_hw_len;
                        pc_i_n = pc_i_n + (is_rvc ? 32'd2 : 32'd4);
                    end
                    else begin
                        id_valid <= 1'b0;
                        id_pc    <= pc_i_n;
                        id_instr <= 32'h0000_0013;
                        id_len   <= 32'd4;
                        id_illegal <= 1'b0;
                        id_illegal_value <= 32'b0;
                        id_fetch_fault <= 1'b0;
                        id_fetch_page_fault <= 1'b0;
                        id_fetch_fault_value <= 32'b0;
                    end
                end

                ibuf         <= ibuf_n;
                ibuf_fetch_fault <= ibuf_fault_n;
                ibuf_fetch_page_fault <= ibuf_page_fault_n;
                ibuf_hw_count <= ibuf_cnt_n;
                pc_i          <= pc_i_n;
                drop_halfword <= drop_n;

                if (halt_now || ex_redirect) begin
                    f2_valid <= 1'b0;
                    f2_word  <= 32'b0;
                    f2_fetch_fault <= 1'b0;
                    f2_fetch_page_fault <= 1'b0;
                end
                else begin
                    f2_valid <= if_valid;
                    if (if_valid) begin
                        f2_word <= core_instr.rdata;
                        f2_fetch_fault <= if_fetch_fault;
                        f2_fetch_page_fault <= if_fetch_page_fault;
                    end
                end
            end

            if (!halted && !halt_now) begin
                if (ex_redirect) begin
                    pc_f     <= {ex_redirect_pc[31:2], 2'b00};
                    if_pc    <= 32'b0;
                    if_valid <= 1'b0;
                    if_fetch_fault <= 1'b0;
                    if_fetch_page_fault <= 1'b0;
                end
                else if (fetch_req && !core_instr.stall) begin
                    if_pc    <= pc_f;
                    if_valid <= 1'b1;
                    if_fetch_fault <= mmu_instr_fault;
                    if_fetch_page_fault <= mmu_instr_page_fault;
                    pc_f     <= pc_f + 32'd4;
                end
                else begin
                    if_pc    <= if_pc;
                    if_valid <= 1'b0;
                    if_fetch_fault <= 1'b0;
                    if_fetch_page_fault <= 1'b0;
                    pc_f     <= pc_f;
                end
            end
            else if (!halted && halt_now) begin
                if_valid <= 1'b0;
            end

            // ID/EX 更新：
            // - flush（redirect/halt）或 load-use stall 时插入 bubble（id_ex_valid=0）。
            // - 除法 stall 时不更新 ID/EX
            if (!halted) begin
                if (halt_now || ex_redirect) begin
                    id_ex_valid <= 1'b0;
                end
                // Backpressure from the current EX instruction must take
                // precedence over a dependency on the following ID
                // instruction.  In particular, a load-use hazard can be
                // asserted while the load is still waiting for a page-table
                // walk.  Dropping ID/EX in that case loses the load entirely.
                else if (stall_div || stall_mem || stall_atomic || stall_mmu) begin
                    // An instruction held in EX can outlive an older producer
                    // in MEM/WB (notably while an Sv32 walk is in progress).
                    // Preserve the producer's retiring value in the held
                    // operand snapshot after the normal forwarding source
                    // disappears.
                    if (wb_we && (mem_wb_rd != 5'd0)) begin
                        if (mem_wb_rd == id_ex_rs1)
                            id_ex_rs1_val <= wb_value;
                        if (mem_wb_rd == id_ex_rs2)
                            id_ex_rs2_val <= wb_value;
                    end
                    if (atomic_wb_valid && (atomic_wb_rd != 5'd0)) begin
                        if (atomic_wb_rd == id_ex_rs1)
                            id_ex_rs1_val <= atomic_wb_value;
                        if (atomic_wb_rd == id_ex_rs2)
                            id_ex_rs2_val <= atomic_wb_value;
                    end
                end
                else if (stall_load_use) begin
                    id_ex_valid <= 1'b0;
                end
                else begin
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
                    id_ex_isCSRRC  <= isCSRRC_d;
                    id_ex_isCSRRW  <= isCSRRW_d;
                    id_ex_isMRET   <= isMRET_d;
                    id_ex_isSRET   <= isSRET_d;
                    id_ex_isWFI    <= isWFI_d;
                    id_ex_isSFENCE <= isSFENCE_d;
                    id_ex_isEBREAK <= isEBREAK_d;
                    id_ex_isECALL  <= isECALL_d;
                    id_ex_isMUL    <= isMUL_d;
                    id_ex_isDIV    <= isDIV_d;
                    id_ex_isFENCE  <= isFENCE_d;
                    id_ex_isAtomic <= isAtomic_d && !illegal_d;
                    id_ex_isLR     <= isLR_d && !illegal_d;
                    id_ex_isSC     <= isSC_d && !illegal_d;
                    id_ex_amo_op   <= amo_op_d;
                    id_ex_aq        <= aq_d;
                    id_ex_rl        <= rl_d;
                    id_ex_illegal   <= illegal_d;
                    id_ex_illegal_value <= id_illegal_value;
                    id_ex_fetch_fault <= id_fetch_fault;
                    id_ex_fetch_page_fault <= id_fetch_page_fault;
                    id_ex_fetch_fault_value <= id_fetch_fault_value;
                end
            end

            // EX/MEM 更新
            if (!halted && !stall_mem && !stall_mmu &&
                (atomic_state == ATOMIC_IDLE) && !ex_mem_isAtomic && !atomic_complete) begin
                ex_mem_valid <= id_ex_valid && !priv_trap_taken;
                ex_mem_rd    <= id_ex_rd;
                ex_mem_isLoad  <= id_ex_isLoad;
                ex_mem_isStore <= id_ex_isStore;
                 ex_mem_isAtomic <= id_ex_valid && id_ex_isAtomic && !priv_trap_taken;
                 ex_mem_isLR <= id_ex_valid && id_ex_isLR && !priv_trap_taken;
                 ex_mem_isSC <= id_ex_valid && id_ex_isSC && !priv_trap_taken;
                ex_mem_funct3  <= id_ex_funct3;
                ex_mem_amo_op <= id_ex_amo_op;
                ex_mem_aq <= id_ex_aq;
                ex_mem_rl <= id_ex_rl;
                ex_mem_rs2_value <= ex_rs2;
                ex_mem_addr    <= d_xlate_req ? d_phys_addr : ex_addr;
                ex_mem_store_wdata <= ex_store_wdata;
                ex_mem_store_wmask <= ex_store_wmask;
                ex_mem_wb_en    <= ex_wb_en;
                ex_mem_wb_value <= ex_wb_value;
            end
            else if (!halted && !stall_mem && stall_mmu &&
                     (atomic_state == ATOMIC_IDLE) && !ex_mem_isAtomic &&
                     !atomic_complete) begin
                // The older EX/MEM item has completed and is consumed by
                // MEM/WB below.  A younger translation miss must prevent a
                // replacement from entering EX/MEM, but must not leave the
                // completed item valid or it will be issued to the bus again.
                ex_mem_valid <= 1'b0;
                ex_mem_isLoad <= 1'b0;
                ex_mem_isStore <= 1'b0;
            end
            else if (atomic_complete) begin
                ex_mem_valid <= 1'b0;
                ex_mem_isAtomic <= 1'b0;
                ex_mem_isLR <= 1'b0;
                ex_mem_isSC <= 1'b0;
            end
            // MEM/WB 更新
            if (atomic_complete) begin
                mem_wb_valid <= 1'b0;
                ex_mem_valid <= 1'b0;
                ex_mem_isAtomic <= 1'b0;
                ex_mem_isLR <= 1'b0;
                ex_mem_isSC <= 1'b0;
                if (atomic_rd != 5'd0)
                    reg_bank[atomic_rd] <= atomic_result;
            end
            else if (!halted && !stall_mem && (atomic_state == ATOMIC_IDLE) && !ex_mem_isAtomic) begin
                mem_wb_valid <= ex_mem_valid;
                mem_wb_rd    <= ex_mem_rd;
                mem_wb_isLoad <= ex_mem_isLoad;
                mem_wb_funct3 <= ex_mem_funct3;
                mem_wb_addr_low <= ex_mem_addr[1:0];
                mem_wb_load_word <= core_data.dat_r;
                mem_wb_wb_en <= ex_mem_wb_en;
                mem_wb_wb_value <= ex_mem_wb_value;
            end
            else if (!halted && !stall_mem) begin
                mem_wb_valid <= 1'b0;
            end


            if (halted || halt_now || ex_redirect || !mem_req || (mem_started && core_data.ack)) begin
                mem_started <= 1'b0;
            end
            else if (mem_req && !mem_started) begin
                mem_started <= 1'b1;
            end
        end
    end

    // ---------------------- 除法器控制信号 ----------------------
    assign div_start = !halted && !stall_mem && !stall_atomic && id_ex_isDIV && id_ex_valid && !div_result_valid && !div_busy;
    assign div_flush = !halted && (ex_redirect || halt_now);

    // ---------------------- 除法器实例化 ----------------------
    divider u_divider (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (div_start),
        .flush        (div_flush),
        .dividend     (ex_rs1),
        .divisor      (ex_rs2),
        .is_signed    (~id_ex_funct3[0]),
        .is_rem       (id_ex_funct3[1]),
        .busy         (div_busy),
        .result_valid (div_result_valid),
        .quotient     (div_result_q),
        .remainder    (div_result_r)
    );

endmodule
