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
        imem_if.master instr,
        simple_bus_if.master data
    );
    import soc_pkg::*;
    import rvc::*;
    // ---------------------- CSR 寄存器 ----------------------
    logic [63:0] csr_cycle;
    logic [63:0] csr_instret;

    logic [31:0] csr_mstatus; // 机器状态 (bit 3: MIE 全局中断使能, bit 7: MPIE 历史中断使能)
    logic [31:0] csr_mie;     // 中断使能寄存器 (bit 11: MEIE, bit 7: MTIE, bit 3: MSIE)
    logic [31:0] csr_mip;     // 中断等待寄存器
    logic [31:0] csr_mtvec;   // 异常入口地址
    logic [31:0] csr_mscratch; // 机器模式下的临时寄存器，异常处理程序可用来保存上下文
    logic [31:0] csr_mepc;    // 异常断点返回地址
    logic [31:0] csr_mcause;  // 异常原因 (最高位 1 代表中断，低位代表中断号)

    always_comb begin
        csr_mip = 32'b0;
        csr_mip[11] = ext_irq;
        csr_mip[7]  = timer_irq;
        csr_mip[3]  = sw_irq;
    end

    // ---------------------- 通用寄存器堆 ----------------------
    logic [31:0] reg_bank [0:31];

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

    // 半字缓存，用来缓存RVC指令
    localparam int unsigned IBUF_HW_MAX = 8;
    logic [16*IBUF_HW_MAX-1:0] ibuf;
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

    logic [31:0] instr_d;
    logic [6:0]  opcode_d;
    logic [4:0]  rs1_d, rs2_d, rd_d;
    logic [2:0]  funct3_d;
    logic [6:0]  funct7_d;

    logic [31:0] Uimm_d, Iimm_d, Simm_d, Bimm_d, Jimm_d;

    logic isALUreg_d, isALUimm_d, isBranch_d, isJALR_d, isJAL_d, isAUIPC_d, isLUI_d;
    logic isLoad_d, isStore_d;
    logic isSYSTEM_d, isMRET_d, isEBREAK_d, isCSRRC_d, isCSRRW_d, isCSRRS_d, isECALL_d;
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

        isMUL_d = id_valid && (opcode_d == 7'b0110011) && (funct7_d == 7'b0000001) && (funct3_d[2] == 1'b0);
        isDIV_d = id_valid && (opcode_d == 7'b0110011) && (funct7_d == 7'b0000001) && (funct3_d[2] == 1'b1);


        isCSRRW_d = isSYSTEM_d && (funct3_d == 3'b001);
        isCSRRS_d = isSYSTEM_d && (funct3_d == 3'b010);
        isCSRRC_d = isSYSTEM_d && (funct3_d == 3'b011);
        isMRET_d  = isSYSTEM_d && (funct3_d == 3'b000) && (instr_d[31:20] == 12'h302);
        isEBREAK_d = isSYSTEM_d && (funct3_d == 3'b000) && (instr_d[31:20] == 12'h001);

        isECALL_d = isSYSTEM_d && (funct3_d == 3'b000) && (instr_d[31:20] == 12'h000);

        // CSR register instructions (CSRRW/CSRRS/CSRRC, funct3[2]=0) use rs1 as write value;
        // must be included in uses_rs1_d so load-use stalls fire correctly when a load
        // result feeds a CSR write (e.g. lw t0, 0(sp) followed by csrw mepc, t0).
        uses_rs1_d = isALUreg_d || isALUimm_d || isBranch_d || isJALR_d || isLoad_d || isStore_d || isMUL_d || isDIV_d
                     || isCSRRW_d || isCSRRS_d || isCSRRC_d;
        uses_rs2_d = isALUreg_d || isBranch_d || isStore_d || isMUL_d || isDIV_d;

        Uimm_d = {instr_d[31], instr_d[30:12], 12'b0};
        Iimm_d = {{21{instr_d[31]}}, instr_d[30:20]};
        Simm_d = {{21{instr_d[31]}}, instr_d[30:25], instr_d[11:7]};
        Bimm_d = {{20{instr_d[31]}}, instr_d[7], instr_d[30:25], instr_d[11:8], 1'b0};
        Jimm_d = {{12{instr_d[31]}}, instr_d[19:12], instr_d[20], instr_d[30:21], 1'b0};
    end

    // 寄存器回写旁路：如果当前指令的源寄存器与 WB 阶段要写回的寄存器相同，则直接使用 WB 的值
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
    logic        id_ex_isCSRRS, id_ex_isCSRRC, id_ex_isCSRRW, id_ex_isMRET, id_ex_isEBREAK, id_ex_isECALL;
    logic        id_ex_isMUL, id_ex_isDIV;

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

    // ---------------------- EX/MEM 流水寄存器 ----------------------
    logic        ex_mem_valid;
    logic [4:0]  ex_mem_rd;
    logic        ex_mem_isLoad, ex_mem_isStore;
    logic [2:0]  ex_mem_funct3;
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
    logic        mem_wb_wb_en;
    logic [31:0] mem_wb_wb_value;

    // ---------------------- 写回（WB）阶段 ----------------------
    // MARK:WB
    logic [31:0] wb_load_data;
    logic [31:0] wb_value;
    logic        wb_we;

    // ---------------------- 冒险检测 ----------------------
    // 这里处理的数据相关：
    // - 大多数 ALU 相关由 EX 阶段前递解决。
    // - Load-use 相关必须停顿，因为加载指令的数据要到 WB 才可用（此实现没有 MEM 级旁路）。
    // - 除法是多周期迭代单元，流水线会一直停住直到 div_result_valid。
    logic stall_load_use;
    logic stall_div;
    logic stall_any;
    always_comb begin
        stall_load_use = 1'b0;
        stall_div = 1'b0;

        // 当前一条指令是 load，且当前指令使用了它加载到的寄存器时，停顿流水线
        if (id_valid && id_ex_valid && id_ex_isLoad && (id_ex_rd != 5'd0)) begin
            if ((uses_rs1_d && (id_ex_rd == rs1_d)) || (uses_rs2_d && (id_ex_rd == rs2_d))) begin
                stall_load_use = 1'b1;
            end
        end

        if (div_busy || (id_ex_isDIV && id_ex_valid && !div_result_valid)) begin
            stall_div = 1'b1;
        end

        stall_any = stall_load_use || stall_div;
    end

    // ---------------------- 前端取指节流 ----------------------
    assign halt_now = (!halted && id_ex_valid && id_ex_isEBREAK);
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

        if (ex_mem_fwd_en && (ex_mem_rd == id_ex_rs1)) begin
            ex_rs1 = ex_mem_wb_value;
        end
        else if (mem_wb_valid && mem_wb_wb_en && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1)) begin
            ex_rs1 = wb_fwd_value;
        end

        if (ex_mem_fwd_en && (ex_mem_rd == id_ex_rs2)) begin
            ex_rs2 = ex_mem_wb_value;
        end
        else if (mem_wb_valid && mem_wb_wb_en && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2)) begin
            ex_rs2 = wb_fwd_value;
        end
    end

    // ---------------------- CSR 读----------------------
    logic [11:0] ex_csr_addr;
    always_comb begin
        ex_csr_addr = id_ex_instr[31:20];

        case (ex_csr_addr)
            12'hc00: ex_csr_rdata = csr_cycle[31:0];
            12'hc80: ex_csr_rdata = csr_cycle[63:32];
            12'hc02: ex_csr_rdata = csr_instret[31:0];
            12'hc82: ex_csr_rdata = csr_instret[63:32];
            12'h300: ex_csr_rdata = csr_mstatus;
            12'h304: ex_csr_rdata = csr_mie;
            12'h305: ex_csr_rdata = csr_mtvec;
            12'h340: ex_csr_rdata = csr_mscratch;
            12'h341: ex_csr_rdata = csr_mepc;
            12'h342: ex_csr_rdata = csr_mcause;
            12'h344: ex_csr_rdata = csr_mip;
            default: ex_csr_rdata = 32'b0;
        endcase
    end
    
    // ------------------------ CSR 写 ----------------------
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
        if (id_ex_valid && !halted) begin
            if (id_ex_isCSRRW) begin
                ex_csr_we = 1'b1;
            end else if ((id_ex_isCSRRS || id_ex_isCSRRC) && (id_ex_rs1 != 5'd0)) begin
                // RISC-V 规定：对于 RS 和 RC，如果 rs1（或 zimm）为 0，则是纯读操作
                ex_csr_we = 1'b1; 
            end
        end
    end

    // ---------------------- 异常与中断判断 ----------------------
    logic trap_req;
    logic [31:0] trap_cause;

    // 全局中断使能
    wire mstatus_mie = csr_mstatus[3]; 
    // 有效的中断请求 = 等待中(mip) & 软件允许(mie)
    wire [31:0] active_irq = csr_mip & csr_mie;

    always_comb begin
        trap_req = 1'b0;
        trap_cause = 32'b0;

        // 硬件中断
        if (mstatus_mie && id_ex_valid && !halt_now) begin
            if (active_irq[11]) begin // 外部中断 (MEIP)
                trap_req = 1'b1;
                trap_cause = 32'h8000_000B; // 最高位为1表示中断，异常码 11
            end else if (active_irq[3]) begin // 软件中断 (MSIP)
                trap_req = 1'b1;
                trap_cause = 32'h8000_0003; 
            end else if (active_irq[7]) begin // 定时器中断 (MTIP)
                trap_req = 1'b1;
                trap_cause = 32'h8000_0007;
            end
        end

        // 软件trap
        if (!trap_req && id_ex_valid) begin
            if (id_ex_isECALL) begin
                trap_req = 1'b1;
                trap_cause = 32'd11; // Machine ECALL
            end else if (id_ex_isEBREAK) begin
                trap_req = 1'b1;
                trap_cause = 32'd3;  // Breakpoint
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_mstatus  <= 32'b0;
            csr_mtvec    <= 32'b0;
            csr_mepc     <= 32'b0;
            csr_mcause   <= 32'b0;
            csr_mscratch <= 32'b0;
            csr_mie      <= 32'b0;
            // csr_mip      <= 32'b0;
        end else begin
            if (trap_req) begin
                // 保存现场
                csr_mepc   <= id_ex_pc;    // 把当前出问题的指令 PC 保存下来
                csr_mcause <= trap_cause;  // 记录是什么原因

                // mstatus 逻辑：MPIE 保存 MIE 的旧值，MIE 置零（关闭全局中断）
                csr_mstatus[7] <= csr_mstatus[3]; 
                csr_mstatus[3] <= 1'b0;
            end 
            else if (id_ex_valid && id_ex_isMRET) begin
                // 恢复现场
                // MIE 恢复为 MPIE 的旧值，MPIE 置一
                csr_mstatus[3] <= csr_mstatus[7];
                csr_mstatus[7] <= 1'b1;
            end 
            else if (ex_csr_we) begin
                case (ex_csr_addr)
                    12'h300: csr_mstatus  <= ex_csr_wdata;
                    12'h304: csr_mie      <= ex_csr_wdata;
                    12'h305: csr_mtvec    <= {ex_csr_wdata[31:2], 2'b00};
                    12'h340: csr_mscratch <= ex_csr_wdata;
                    12'h341: csr_mepc     <= {ex_csr_wdata[31:1], 1'b0};  // RVC: preserve bit[1] for 2-byte alignment
                    12'h342: csr_mcause   <= ex_csr_wdata;
                    // ! IMPORTANT
                    // 注意：真实实现中，mstatus、mie 等有些位是只读（Hardwired to 0）的。
                    // 为了简化，目前允许全写。日后可加掩码，例如：csr_mstatus <= ex_csr_wdata & 32'h0000_1888;
                endcase
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

        ex_addr = ex_rs1 + (id_ex_isStore ? id_ex_Simm : id_ex_Iimm);

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
                           ex_alu_out = id_ex_funct7[5] ? ($signed(ex_rs1) >>> shamt) : (ex_rs1 >> shamt);
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
                      if (trap_req) begin
                          ex_redirect = 1'b1;
                          ex_redirect_pc = {csr_mtvec[31:2], 2'b00}; 

                          ex_wb_en = 1'b0;
                          ex_store_wmask = 4'b0000;
                      end 
                      // mret
                      else if (id_ex_valid && id_ex_isMRET) begin
                          ex_redirect = 1'b1;
                          ex_redirect_pc = csr_mepc;
                      end
                      else if (id_ex_valid) begin
                          if (id_ex_isBranch && ex_take_branch) begin
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
    end

    // ---------------------- WB 阶段加载数据格式化 ----------------------
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

    // ---------------------- 总线驱动 ----------------------
    always_comb begin
        instr.addr = pc_f;
        instr.ren  = !halted;

        data.addr  = ex_mem_addr;
        data.ren   = !halted && ex_mem_valid && ex_mem_isLoad;
        data.wen   = !halted && ex_mem_valid && ex_mem_isStore;
        data.wdata = ex_mem_store_wdata;
        data.wstrb = (!halted && ex_mem_valid && ex_mem_isStore) ? ex_mem_store_wmask : 4'b0000;
    end

    // ---------------------- 时序逻辑 ----------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            halted <= 1'b0;

            {pc_f, if_valid, if_pc, f2_word, f2_valid} <= '0;
            {id_valid, id_pc, id_instr} <= '0;

            {ibuf, ibuf_hw_count, pc_i, drop_halfword} <= '0;

            { id_ex_valid, id_ex_pc, id_ex_instr,
              id_ex_rs1, id_ex_rs2, id_ex_rd,
              id_ex_funct3, id_ex_funct7,
              id_ex_rs1_val, id_ex_rs2_val,
              id_ex_Uimm, id_ex_Iimm, id_ex_Simm, id_ex_Bimm, id_ex_Jimm,
              id_ex_isALUreg, id_ex_isALUimm, id_ex_isBranch, id_ex_isJALR, id_ex_isJAL,
              id_ex_isAUIPC, id_ex_isLUI, id_ex_isLoad, id_ex_isStore, id_ex_isCSRRS, id_ex_isEBREAK,
              id_ex_isMUL, id_ex_isDIV
            } <= '0;

            { ex_mem_valid, ex_mem_rd, ex_mem_isLoad, ex_mem_isStore, ex_mem_funct3,
              ex_mem_addr, ex_mem_store_wdata, ex_mem_store_wmask, ex_mem_wb_en, ex_mem_wb_value
            } <= '0;

            { mem_wb_valid, mem_wb_rd, mem_wb_isLoad, mem_wb_funct3, mem_wb_addr_low,
              mem_wb_wb_en, mem_wb_wb_value
            } <= '0;

            {csr_cycle, csr_instret} <= '0;

            id_len    <= 32'd4;
            id_ex_len <= 32'd4;
        end
        else begin
            csr_cycle <= csr_cycle + 64'd1;

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
                end
                else begin
                    if (f2_valid) begin
                        ibuf_n[16*ibuf_cnt_n +: 16] = f2_word[15:0];
                        ibuf_n[16*(ibuf_cnt_n + 1) +: 16] = f2_word[31:16];
                        ibuf_cnt_n = ibuf_cnt_n + 2;
                    end

                    // redirect 后若目标落在 word 内部（2-byte 对齐但非 4-byte），丢弃一个 halfword 以对齐到正确的指令边界。
                    if (drop_n && (ibuf_cnt_n != 0)) begin
                        ibuf_n = ibuf_n >> 16;
                        ibuf_cnt_n = ibuf_cnt_n - 1;
                        drop_n = 1'b0;
                    end
                end

                if (halt_now || ex_redirect) begin
                    id_valid <= 1'b0;
                    id_pc    <= 32'b0;
                    id_instr <= 32'h0000_0013; // NOP
                    id_len   <= 32'd4;
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

                        ibuf_n = ibuf_n >> (16 * inst_hw_len);
                        ibuf_cnt_n = ibuf_cnt_n - inst_hw_len;
                        pc_i_n = pc_i_n + (is_rvc ? 32'd2 : 32'd4);
                    end
                    else begin
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

                if (halt_now || ex_redirect) begin
                    f2_valid <= 1'b0;
                    f2_word  <= 32'b0;
                end
                else begin
                    f2_valid <= if_valid;
                    if (if_valid) begin
                        f2_word <= instr.rdata;
                    end
                end
            end

            if (!halted && !halt_now) begin
                if (ex_redirect) begin
                    pc_f     <= {ex_redirect_pc[31:2], 2'b00};
                    if_pc    <= 32'b0;
                    if_valid <= 1'b0;
                end
                else if (fetch_req) begin
                    if_pc    <= pc_f;
                    if_valid <= 1'b1;
                    pc_f     <= pc_f + 32'd4;
                end
                else begin
                    if_pc    <= if_pc;
                    if_valid <= 1'b0;
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
                if (halt_now || ex_redirect || stall_load_use) begin
                    id_ex_valid <= 1'b0;
                end
                else if (!stall_div) begin
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
                    id_ex_isEBREAK <= isEBREAK_d;
                    id_ex_isECALL  <= isECALL_d;
                    id_ex_isMUL    <= isMUL_d;
                    id_ex_isDIV    <= isDIV_d;
                end
            end

            // EX/MEM 更新
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

            // MEM/WB 更新
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

    // ---------------------- 除法器控制信号 ----------------------
    assign div_start = !halted && id_ex_isDIV && id_ex_valid && !div_result_valid && !div_busy;
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

`ifdef BENCH
    integer i;
    initial begin
        for (i = 0; i < 32; ++i) begin
            reg_bank[i] = 0;
        end
    end
`endif
endmodule
