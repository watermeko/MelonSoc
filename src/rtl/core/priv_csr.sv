`ifndef MELONSOC_PRIV_CSR_SV
`define MELONSOC_PRIV_CSR_SV

module priv_csr (
        input  logic        clk,
        input  logic        rst_n,
        input  logic [31:0] irq_pending_i,
        input  logic        ex_valid_i,
        input  logic        ex_fire_i,
        input  logic [31:0] ex_pc_i,
        input  logic        csr_valid_i,
        input  logic [11:0] csr_addr_i,
        input  logic        csr_write_i,
        input  logic [31:0] csr_wdata_i,
        output logic [31:0] csr_rdata_o,
        output logic        csr_illegal_o,
        input  logic        exception_valid_i,
        input  logic [31:0] exception_cause_i,
        input  logic [31:0] exception_tval_i,
        input  logic        mret_i,
        input  logic        sret_i,
        input  logic        sfence_vma_i,
        input  logic        wfi_i,
        output logic        xret_illegal_o,
        input  logic        retire_i,
        output logic        trap_taken_o,
        output logic        return_taken_o,
        output logic        redirect_valid_o,
        output logic [31:0] redirect_pc_o,
        output logic [1:0]  privilege_o,
        output logic [31:0] mstatus_o,
        output logic [31:0] satp_o
    );
    localparam logic [1:0] PRIV_U = 2'b00;
    localparam logic [1:0] PRIV_S = 2'b01;
    localparam logic [1:0] PRIV_M = 2'b11;

    localparam logic [31:0] MISA_VALUE = 32'h4014_1105; // RV32IMACSU
    localparam logic [31:0] MSTATUS_MASK = 32'h007e_19aa;
    localparam logic [31:0] SSTATUS_MASK = 32'h000c_0122;
    localparam logic [31:0] MEDELEG_MASK = 32'h0000_b3ff;
    localparam logic [31:0] MIDELEG_MASK = 32'h0000_0222;
    localparam logic [31:0] IRQ_MASK = 32'h0000_0aaa;
    localparam logic [31:0] SIP_WRITE_MASK = 32'h0000_0002;
    localparam logic [31:0] MIP_WRITE_MASK = 32'h0000_0222;

    logic [1:0] current_priv;
    logic [31:0] mstatus;
    logic [31:0] medeleg;
    logic [31:0] mideleg;
    logic [31:0] mie;
    logic [31:0] mtvec;
    logic [31:0] mcounteren;
    logic [31:0] mscratch;
    logic [31:0] mepc;
    logic [31:0] mcause;
    logic [31:0] mtval;
    logic [31:0] stvec;
    logic [31:0] scounteren;
    logic [31:0] sscratch;
    logic [31:0] sepc;
    logic [31:0] scause;
    logic [31:0] stval;
    logic [31:0] satp;
    logic [31:0] supervisor_pending;
    logic [63:0] cycle_counter;
    logic [63:0] instret_counter;

    logic csr_implemented;
    logic counter_allowed;
    logic [31:0] mip_value;
    logic [31:0] pending_enabled;
    logic interrupt_valid;
    logic [4:0] interrupt_code;
    logic interrupt_to_s;
    logic trap_to_s;
    logic [31:0] trap_vector;

    function automatic logic [31:0] warl_mstatus(input logic [31:0] value);
        logic [31:0] result;
        begin
            result = value & MSTATUS_MASK;
            if (result[12:11] == 2'b10)
                result[12:11] = PRIV_U;
            return result;
        end
    endfunction

    assign privilege_o = current_priv;
    assign mstatus_o = mstatus;
    assign satp_o = satp;
    assign mip_value = (irq_pending_i & 32'h0000_0888) |
                       (supervisor_pending & MIDELEG_MASK);

    always_comb begin
        csr_implemented = 1'b1;
        csr_rdata_o = 32'b0;
        unique case (csr_addr_i)
            12'h100: csr_rdata_o = mstatus & SSTATUS_MASK;
            12'h104: csr_rdata_o = mie & mideleg;
            12'h105: csr_rdata_o = stvec;
            12'h106: csr_rdata_o = scounteren;
            12'h140: csr_rdata_o = sscratch;
            12'h141: csr_rdata_o = sepc;
            12'h142: csr_rdata_o = scause;
            12'h143: csr_rdata_o = stval;
            12'h144: csr_rdata_o = mip_value & mideleg;
            12'h180: csr_rdata_o = satp;
            12'h300: csr_rdata_o = mstatus;
            12'h301: csr_rdata_o = MISA_VALUE;
            12'h302: csr_rdata_o = medeleg;
            12'h303: csr_rdata_o = mideleg;
            12'h304: csr_rdata_o = mie;
            12'h305: csr_rdata_o = mtvec;
            12'h306: csr_rdata_o = mcounteren;
            12'h310: csr_rdata_o = 32'b0; // mstatush: fixed little-endian RV32.
            12'h340: csr_rdata_o = mscratch;
            12'h341: csr_rdata_o = mepc;
            12'h342: csr_rdata_o = mcause;
            12'h343: csr_rdata_o = mtval;
            12'h344: csr_rdata_o = mip_value;
            12'hb00: csr_rdata_o = cycle_counter[31:0];
            12'hb80: csr_rdata_o = cycle_counter[63:32];
            12'hb02: csr_rdata_o = instret_counter[31:0];
            12'hb82: csr_rdata_o = instret_counter[63:32];
            12'hc00: csr_rdata_o = cycle_counter[31:0];
            12'hc01: csr_rdata_o = cycle_counter[31:0];
            12'hc80: csr_rdata_o = cycle_counter[63:32];
            12'hc81: csr_rdata_o = cycle_counter[63:32];
            12'hc02: csr_rdata_o = instret_counter[31:0];
            12'hc82: csr_rdata_o = instret_counter[63:32];
            12'hf11: csr_rdata_o = 32'b0;
            12'hf12: csr_rdata_o = 32'b0;
            12'hf13: csr_rdata_o = 32'b0;
            12'hf14: csr_rdata_o = 32'b0;
            default: begin
                csr_implemented = 1'b0;
                csr_rdata_o = 32'b0;
            end
        endcase
    end

    always_comb begin
        counter_allowed = 1'b1;
        if ((csr_addr_i == 12'hc00) || (csr_addr_i == 12'hc80)) begin
            if (current_priv == PRIV_S)
                counter_allowed = mcounteren[0];
            else if (current_priv == PRIV_U)
                counter_allowed = mcounteren[0] && scounteren[0];
        end
        else if ((csr_addr_i == 12'hc01) || (csr_addr_i == 12'hc81)) begin
            if (current_priv == PRIV_S)
                counter_allowed = mcounteren[1];
            else if (current_priv == PRIV_U)
                counter_allowed = mcounteren[1] && scounteren[1];
        end
        else if ((csr_addr_i == 12'hc02) || (csr_addr_i == 12'hc82)) begin
            if (current_priv == PRIV_S)
                counter_allowed = mcounteren[2];
            else if (current_priv == PRIV_U)
                counter_allowed = mcounteren[2] && scounteren[2];
        end

        csr_illegal_o = csr_valid_i &&
                        (!csr_implemented ||
                         (current_priv < csr_addr_i[9:8]) ||
                         (csr_write_i && (csr_addr_i[11:10] == 2'b11)) ||
                         !counter_allowed ||
                         ((csr_addr_i == 12'h180) && mstatus[20] &&
                          (current_priv == PRIV_S)));
        xret_illegal_o = (mret_i && (current_priv != PRIV_M)) ||
                         (sret_i && ((current_priv == PRIV_U) ||
                                     ((current_priv == PRIV_S) && mstatus[22]))) ||
                         (sfence_vma_i && ((current_priv == PRIV_U) ||
                                          ((current_priv == PRIV_S) && mstatus[20]))) ||
                         (wfi_i && ((current_priv == PRIV_U) ||
                                    ((current_priv == PRIV_S) && mstatus[21])));
    end

    always_comb begin
        logic m_irq_enabled;
        logic s_irq_enabled;
        logic [31:0] m_candidates;
        logic [31:0] s_candidates;

        pending_enabled = mip_value & mie & IRQ_MASK;
        m_irq_enabled = (current_priv < PRIV_M) ||
                        ((current_priv == PRIV_M) && mstatus[3]);
        s_irq_enabled = (current_priv == PRIV_U) ||
                        ((current_priv == PRIV_S) && mstatus[1]);
        m_candidates = pending_enabled & ~mideleg;
        s_candidates = pending_enabled & mideleg;

        interrupt_valid = 1'b0;
        interrupt_code = 5'b0;
        interrupt_to_s = 1'b0;
        if (m_irq_enabled && (m_candidates != 0)) begin
            interrupt_valid = 1'b1;
            if (m_candidates[11]) interrupt_code = 5'd11;
            else if (m_candidates[3]) interrupt_code = 5'd3;
            else if (m_candidates[7]) interrupt_code = 5'd7;
            else if (m_candidates[9]) interrupt_code = 5'd9;
            else if (m_candidates[1]) interrupt_code = 5'd1;
            else interrupt_code = 5'd5;
        end
        else if ((current_priv != PRIV_M) && s_irq_enabled && (s_candidates != 0)) begin
            interrupt_valid = 1'b1;
            interrupt_to_s = 1'b1;
            if (s_candidates[9]) interrupt_code = 5'd9;
            else if (s_candidates[1]) interrupt_code = 5'd1;
            else interrupt_code = 5'd5;
        end
    end

    always_comb begin
        logic [31:0] selected_cause;
        logic selected_interrupt;
        logic [4:0] cause_index;

        selected_cause = exception_cause_i;
        selected_interrupt = 1'b0;
        trap_to_s = 1'b0;
        if (exception_valid_i) begin
            cause_index = exception_cause_i[4:0];
            trap_to_s = (current_priv != PRIV_M) && medeleg[cause_index];
        end
        else begin
            cause_index = interrupt_code;
            selected_cause = 32'h8000_0000 | {27'b0, interrupt_code};
            selected_interrupt = 1'b1;
            trap_to_s = interrupt_to_s;
        end

        trap_vector = trap_to_s ? stvec : mtvec;
        trap_taken_o = ex_fire_i &&
                       (exception_valid_i || (!exception_valid_i && interrupt_valid));
        return_taken_o = ex_fire_i && !trap_taken_o && !xret_illegal_o &&
                         (mret_i || sret_i);
        redirect_valid_o = trap_taken_o || return_taken_o;
        redirect_pc_o = 32'b0;
        if (trap_taken_o) begin
            redirect_pc_o = {trap_vector[31:2], 2'b00};
            if (selected_interrupt && (trap_vector[1:0] == 2'b01))
                redirect_pc_o = {trap_vector[31:2], 2'b00} +
                                ({27'b0, interrupt_code} << 2);
        end
        else if (return_taken_o) begin
            redirect_pc_o = mret_i ? mepc : sepc;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_priv <= PRIV_M;
            mstatus <= 32'b0;
            medeleg <= 32'b0;
            mideleg <= 32'b0;
            mie <= 32'b0;
            mtvec <= 32'b0;
            mcounteren <= 32'b0;
            mscratch <= 32'b0;
            mepc <= 32'b0;
            mcause <= 32'b0;
            mtval <= 32'b0;
            stvec <= 32'b0;
            scounteren <= 32'b0;
            sscratch <= 32'b0;
            sepc <= 32'b0;
            scause <= 32'b0;
            stval <= 32'b0;
            satp <= 32'b0;
            supervisor_pending <= 32'b0;
            cycle_counter <= 64'b0;
            instret_counter <= 64'b0;
        end
        else begin
            cycle_counter <= cycle_counter + 64'd1;
            if (retire_i)
                instret_counter <= instret_counter + 64'd1;

            if (trap_taken_o) begin
                if (trap_to_s) begin
                    sepc <= {ex_pc_i[31:1], 1'b0};
                    scause <= exception_valid_i ? exception_cause_i :
                              (32'h8000_0000 | {27'b0, interrupt_code});
                    stval <= exception_valid_i ? exception_tval_i : 32'b0;
                    mstatus[5] <= mstatus[1];
                    mstatus[1] <= 1'b0;
                    mstatus[8] <= (current_priv == PRIV_S);
                    current_priv <= PRIV_S;
                end
                else begin
                    mepc <= {ex_pc_i[31:1], 1'b0};
                    mcause <= exception_valid_i ? exception_cause_i :
                              (32'h8000_0000 | {27'b0, interrupt_code});
                    mtval <= exception_valid_i ? exception_tval_i : 32'b0;
                    mstatus[7] <= mstatus[3];
                    mstatus[3] <= 1'b0;
                    mstatus[12:11] <= current_priv;
                    current_priv <= PRIV_M;
                end
            end
            else if (return_taken_o) begin
                if (mret_i) begin
                    current_priv <= mstatus[12:11];
                    mstatus[3] <= mstatus[7];
                    mstatus[7] <= 1'b1;
                    if (mstatus[12:11] != PRIV_M)
                        mstatus[17] <= 1'b0;
                    mstatus[12:11] <= PRIV_U;
                end
                else begin
                    current_priv <= mstatus[8] ? PRIV_S : PRIV_U;
                    mstatus[1] <= mstatus[5];
                    mstatus[5] <= 1'b1;
                    mstatus[8] <= 1'b0;
                    mstatus[17] <= 1'b0;
                end
            end
            else if (ex_fire_i && csr_valid_i && csr_write_i && !csr_illegal_o) begin
                unique case (csr_addr_i)
                    12'h100: mstatus <= (mstatus & ~SSTATUS_MASK) |
                                          (csr_wdata_i & SSTATUS_MASK);
                    12'h104: mie <= (mie & ~mideleg) |
                                      (csr_wdata_i & mideleg & IRQ_MASK);
                    12'h105: stvec <= (csr_wdata_i[1:0] <= 2'b01) ?
                                      {csr_wdata_i[31:2], csr_wdata_i[1:0]} :
                                      {csr_wdata_i[31:2], 2'b00};
                    12'h106: scounteren <= csr_wdata_i & 32'h0000_0007;
                    12'h140: sscratch <= csr_wdata_i;
                    12'h141: sepc <= {csr_wdata_i[31:1], 1'b0};
                    12'h142: scause <= csr_wdata_i;
                    12'h143: stval <= csr_wdata_i;
                    12'h144: supervisor_pending <=
                              (supervisor_pending & ~SIP_WRITE_MASK) |
                              (csr_wdata_i & SIP_WRITE_MASK);
                    12'h180: satp <= csr_wdata_i;
                    12'h300: mstatus <= warl_mstatus(csr_wdata_i);
                    12'h302: medeleg <= csr_wdata_i & MEDELEG_MASK;
                    12'h303: mideleg <= csr_wdata_i & MIDELEG_MASK;
                    12'h304: mie <= csr_wdata_i & IRQ_MASK;
                    12'h305: mtvec <= (csr_wdata_i[1:0] <= 2'b01) ?
                                      {csr_wdata_i[31:2], csr_wdata_i[1:0]} :
                                      {csr_wdata_i[31:2], 2'b00};
                    12'h306: mcounteren <= csr_wdata_i & 32'h0000_0007;
                    12'h340: mscratch <= csr_wdata_i;
                    12'h341: mepc <= {csr_wdata_i[31:1], 1'b0};
                    12'h342: mcause <= csr_wdata_i;
                    12'h343: mtval <= csr_wdata_i;
                    12'h344: supervisor_pending <=
                              (supervisor_pending & ~MIP_WRITE_MASK) |
                              (csr_wdata_i & MIP_WRITE_MASK);
                    12'hb00: cycle_counter[31:0] <= csr_wdata_i;
                    12'hb80: cycle_counter[63:32] <= csr_wdata_i;
                    12'hb02: instret_counter[31:0] <= csr_wdata_i;
                    12'hb82: instret_counter[63:32] <= csr_wdata_i;
                    default: begin end
                endcase
            end

        end
    end
endmodule

`endif
