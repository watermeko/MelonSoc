`ifndef MELONSOC_SV32_MMU_SV
`define MELONSOC_SV32_MMU_SV

`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"

module sv32_mmu (
        input logic clk,
        input logic rst_n,
        input logic [31:0] satp_i,
        input logic [31:0] mstatus_i,
        input logic [1:0] privilege_i,
        input logic sfence_vma_i,
        input logic frontend_flush_i,
        imem_if.slave core_instr,
        imem_if.master phys_instr,
        input logic d_req_valid_i,
        input logic [31:0] d_vaddr_i,
        input logic d_store_i,
        output logic d_req_ready_o,
        output logic [31:0] d_paddr_o,
        output logic d_page_fault_o,
        output logic d_access_fault_o,
        output logic instr_fault_o,
        output logic instr_page_fault_o,
        output logic [31:0] instr_fault_vaddr_o,
        wb_if.slave core_data,
        wb_if.master phys_data
    );
    import soc_pkg::*;

    localparam logic [1:0] PRIV_U = 2'b00;
    localparam logic [1:0] PRIV_S = 2'b01;
    localparam logic [1:0] PRIV_M = 2'b11;
    localparam int unsigned TLB_ENTRIES = 4;

    typedef struct packed {
        logic valid;
        logic global_mapping;
        logic superpage;
        logic [8:0] asid;
        logic [19:0] vpn;
        logic [21:0] ppn;
        logic u;
        logic r;
        logic w;
        logic x;
        logic a;
        logic d;
    } tlb_entry_t;

    typedef enum logic [3:0] {
        PTW_IDLE,
        PTW_L1_WAIT,
        PTW_L1_CAPTURE,
        PTW_L1_CHECK,
        PTW_L0_WAIT,
        PTW_L0_CAPTURE,
        PTW_L0_CHECK,
        PTW_FILL,
        PTW_FAULT
    } ptw_state_t;

    tlb_entry_t dtlb [0:TLB_ENTRIES-1];
    tlb_entry_t itlb [0:TLB_ENTRIES-1];
    logic [1:0] dtlb_replace;
    logic [1:0] itlb_replace;
    ptw_state_t ptw_state;
    logic [31:0] walk_vaddr;
    logic walk_store;
    logic walk_is_instr;
    logic [1:0] walk_priv;
    logic [8:0] walk_asid;
    logic walk_sum;
    logic walk_mxr;
    logic walk_global;
    logic [31:0] walk_pte_addr;
    logic [31:0] walk_pte;
    logic walk_superpage;
    logic walk_page_fault;
    logic walk_access_fault;
    logic instr_fault_pending;
    logic instr_fault_page;
    logic [31:0] instr_fault_vaddr;

    logic [1:0] effective_priv;
    logic data_translate;
    logic dtlb_hit;
    logic [1:0] dtlb_hit_index;
    logic dtlb_permission_ok;
    logic [33:0] dtlb_pa;
    logic walk_active;
    logic instr_translate;
    logic itlb_hit;
    logic [1:0] itlb_hit_index;
    logic itlb_permission_ok;
    logic [33:0] itlb_pa;
    logic instr_direct_page_fault;
    logic instr_direct_access_fault;
    always_comb begin
        effective_priv = privilege_i;
        if ((privilege_i == PRIV_M) && mstatus_i[17])
            effective_priv = mstatus_i[12:11];
        data_translate = satp_i[31] && (effective_priv != PRIV_M);
        instr_translate = satp_i[31] && (privilege_i != PRIV_M);
    end


    always_comb begin
        itlb_hit = 1'b0;
        itlb_hit_index = 2'b0;
        for (int lookup_i = 0; lookup_i < TLB_ENTRIES; lookup_i++) begin
            if (!itlb_hit && itlb[lookup_i].valid &&
                (itlb[lookup_i].global_mapping || (itlb[lookup_i].asid == satp_i[30:22])) &&
                (itlb[lookup_i].superpage ?
                 (itlb[lookup_i].vpn[19:10] == core_instr.addr[31:22]) :
                 (itlb[lookup_i].vpn == core_instr.addr[31:12]))) begin
                itlb_hit = 1'b1;
                itlb_hit_index = lookup_i[1:0];
            end
        end
    end

    always_comb begin
        tlb_entry_t hit;
        hit = itlb[itlb_hit_index];
        itlb_permission_ok = hit.x && hit.a &&
                             ((privilege_i == PRIV_U) ? hit.u : !hit.u);
        itlb_pa = hit.superpage ?
                  {hit.ppn[21:10], core_instr.addr[21:0]} :
                  {hit.ppn, core_instr.addr[11:0]};
        instr_direct_page_fault = instr_translate && core_instr.ren &&
                                  itlb_hit && !itlb_permission_ok;
        instr_direct_access_fault = instr_translate && core_instr.ren &&
                                    itlb_hit && itlb_permission_ok &&
                                    (|itlb_pa[33:32]);
    end

    always_comb begin
        dtlb_hit = 1'b0;
        dtlb_hit_index = 2'b0;
        for (int lookup_i = 0; lookup_i < TLB_ENTRIES; lookup_i++) begin
            if (!dtlb_hit && dtlb[lookup_i].valid &&
                (dtlb[lookup_i].global_mapping || (dtlb[lookup_i].asid == satp_i[30:22])) &&
                (dtlb[lookup_i].superpage ?
                 (dtlb[lookup_i].vpn[19:10] == d_vaddr_i[31:22]) :
                 (dtlb[lookup_i].vpn == d_vaddr_i[31:12]))) begin
                dtlb_hit = 1'b1;
                dtlb_hit_index = lookup_i[1:0];
            end
        end
    end

    always_comb begin
        logic allow_priv;
        logic allow_access;
        tlb_entry_t hit;

        hit = dtlb[dtlb_hit_index];
        allow_priv = 1'b0;
        if (effective_priv == PRIV_U)
            allow_priv = hit.u;
        else if (effective_priv == PRIV_S)
            allow_priv = !hit.u || mstatus_i[18];
        else
            allow_priv = 1'b1;

        allow_access = d_store_i ? hit.w : (hit.r || (mstatus_i[19] && hit.x));
        dtlb_permission_ok = allow_priv && allow_access && hit.a &&
                             (!d_store_i || hit.d);
        dtlb_pa = hit.superpage ?
                  {hit.ppn[21:10], d_vaddr_i[21:0]} :
                  {hit.ppn, d_vaddr_i[11:0]};
    end

    always_comb begin
        d_req_ready_o = 1'b0;
        d_paddr_o = d_vaddr_i;
        d_page_fault_o = 1'b0;
        d_access_fault_o = 1'b0;
        if (!d_req_valid_i) begin
            d_req_ready_o = 1'b1;
        end
        else if (!data_translate) begin
            d_req_ready_o = 1'b1;
        end
        else if (dtlb_hit) begin
            d_req_ready_o = 1'b1;
            d_paddr_o = dtlb_pa[31:0];
            d_page_fault_o = !dtlb_permission_ok;
            d_access_fault_o = dtlb_permission_ok && (|dtlb_pa[33:32]);
        end
        else if ((ptw_state == PTW_FAULT) && (walk_vaddr == d_vaddr_i) &&
                 (walk_store == d_store_i)) begin
            d_req_ready_o = 1'b1;
            d_page_fault_o = walk_page_fault;
            d_access_fault_o = walk_access_fault;
        end
    end

    assign walk_active = (ptw_state == PTW_L1_WAIT) ||
                         (ptw_state == PTW_L0_WAIT);

    always_comb begin
        phys_instr.addr = instr_translate ? itlb_pa[31:0] : core_instr.addr;
        phys_instr.ren = core_instr.ren &&
                         (!instr_translate || (itlb_hit && itlb_permission_ok &&
                                               !(|itlb_pa[33:32])));
        core_instr.rdata = phys_instr.rdata;
        core_instr.stall = phys_instr.stall;
        if (instr_translate && core_instr.ren) begin
            if (instr_fault_pending && (instr_fault_vaddr == core_instr.addr))
                core_instr.stall = 1'b0;
            else if (instr_direct_page_fault || instr_direct_access_fault)
                core_instr.stall = 1'b0;
            else if (!itlb_hit)
                core_instr.stall = 1'b1;
        end

        if (walk_active) begin
            phys_data.adr = walk_pte_addr;
            phys_data.dat_w = 32'b0;
            phys_data.sel = 4'b1111;
            phys_data.we = 1'b0;
            phys_data.cyc = 1'b1;
            phys_data.stb = 1'b1;
            phys_data.lock = 1'b0;
            core_data.dat_r = 32'b0;
            core_data.ack = 1'b0;
            core_data.stall = core_data.cyc;
        end
        else begin
            phys_data.adr = core_data.adr;
            phys_data.dat_w = core_data.dat_w;
            phys_data.sel = core_data.sel;
            phys_data.we = core_data.we;
            phys_data.cyc = core_data.cyc;
            phys_data.stb = core_data.stb;
            phys_data.lock = core_data.lock;
            core_data.dat_r = phys_data.dat_r;
            core_data.ack = phys_data.ack;
            core_data.stall = phys_data.stall;
        end
    end


    assign instr_fault_o = instr_fault_pending || instr_direct_page_fault ||
                           instr_direct_access_fault;
    assign instr_page_fault_o = instr_fault_pending ? instr_fault_page :
                                instr_direct_page_fault;
    assign instr_fault_vaddr_o = instr_fault_pending ? instr_fault_vaddr :
                                 core_instr.addr;

    function automatic logic pte_invalid(input logic [31:0] pte);
        return !pte[0] || (!pte[1] && pte[2]);
    endfunction

    function automatic logic pte_permission_ok(
        input logic [31:0] pte,
        input logic store_access,
        input logic [1:0] access_priv,
        input logic sum,
        input logic mxr
    );
        logic allow_priv;
        logic allow_access;
        begin
            allow_priv = (access_priv == PRIV_U) ? pte[4] :
                         (access_priv == PRIV_S) ? (!pte[4] || sum) : 1'b1;
            allow_access = store_access ? pte[2] : (pte[1] || (mxr && pte[3]));
            return allow_priv && allow_access && pte[6] &&
                   (!store_access || pte[7]);
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ptw_state <= PTW_IDLE;
            dtlb_replace <= 2'b0;
            itlb_replace <= 2'b0;
            walk_vaddr <= 32'b0;
            walk_store <= 1'b0;
            walk_is_instr <= 1'b0;
            walk_priv <= PRIV_M;
            walk_asid <= 9'b0;
            walk_sum <= 1'b0;
            walk_mxr <= 1'b0;
            walk_global <= 1'b0;
            walk_pte_addr <= 32'b0;
            walk_pte <= 32'b0;
            walk_superpage <= 1'b0;
            walk_page_fault <= 1'b0;
            walk_access_fault <= 1'b0;
            instr_fault_pending <= 1'b0;
            instr_fault_page <= 1'b0;
            instr_fault_vaddr <= 32'b0;
            for (int reset_i = 0; reset_i < TLB_ENTRIES; reset_i++) begin
                dtlb[reset_i] <= '0;
                itlb[reset_i] <= '0;
            end
        end
        else begin
            if (sfence_vma_i) begin
                for (int flush_i = 0; flush_i < TLB_ENTRIES; flush_i++) begin
                    dtlb[flush_i].valid <= 1'b0;
                    itlb[flush_i].valid <= 1'b0;
                end
            end

            if (frontend_flush_i)
                instr_fault_pending <= 1'b0;
            else if (instr_fault_pending && core_instr.ren && !core_instr.stall)
                instr_fault_pending <= 1'b0;

            unique case (ptw_state)
                PTW_IDLE: begin
                    if (d_req_valid_i && data_translate && !dtlb_hit &&
                        !core_data.cyc) begin
                        walk_vaddr <= d_vaddr_i;
                        walk_store <= d_store_i;
                        walk_is_instr <= 1'b0;
                        walk_priv <= effective_priv;
                        walk_asid <= satp_i[30:22];
                        walk_sum <= mstatus_i[18];
                        walk_mxr <= mstatus_i[19];
                        walk_global <= 1'b0;
                        walk_page_fault <= 1'b0;
                        walk_access_fault <= 1'b0;
                        walk_pte_addr <= {satp_i[19:0], 12'b0} +
                                         {20'b0, d_vaddr_i[31:22], 2'b0};
                        if ((satp_i[21:20] != 0) ||
                            !is_dataram_region({satp_i[19:0], 12'b0} +
                                               {20'b0, d_vaddr_i[31:22], 2'b0}) &&
                            !is_ddr_region({satp_i[19:0], 12'b0} +
                                           {20'b0, d_vaddr_i[31:22], 2'b0})) begin
                            walk_access_fault <= 1'b1;
                            ptw_state <= PTW_FAULT;
                        end
                        else begin
                            ptw_state <= PTW_L1_WAIT;
                        end
                    end
                    else if (core_instr.ren && instr_translate && !itlb_hit &&
                             !core_data.cyc && !instr_fault_pending) begin
                        walk_vaddr <= core_instr.addr;
                        walk_store <= 1'b0;
                        walk_is_instr <= 1'b1;
                        walk_priv <= privilege_i;
                        walk_asid <= satp_i[30:22];
                        walk_sum <= 1'b0;
                        walk_mxr <= 1'b0;
                        walk_global <= 1'b0;
                        walk_page_fault <= 1'b0;
                        walk_access_fault <= 1'b0;
                        walk_pte_addr <= {satp_i[19:0], 12'b0} +
                                         {20'b0, core_instr.addr[31:22], 2'b0};
                        if ((satp_i[21:20] != 0) ||
                            (!is_dataram_region({satp_i[19:0], 12'b0} +
                                                {20'b0, core_instr.addr[31:22], 2'b0}) &&
                             !is_ddr_region({satp_i[19:0], 12'b0} +
                                            {20'b0, core_instr.addr[31:22], 2'b0}))) begin
                            walk_access_fault <= 1'b1;
                            ptw_state <= PTW_FAULT;
                        end
                        else begin
                            ptw_state <= PTW_L1_WAIT;
                        end
                    end
                end
                PTW_L1_WAIT: begin
                    if (phys_data.ack)
                        ptw_state <= PTW_L1_CAPTURE;
                end
                PTW_L1_CAPTURE: begin
                    walk_pte <= phys_data.dat_r;
                    ptw_state <= PTW_L1_CHECK;
                end
                PTW_L1_CHECK: begin
                    walk_global <= walk_global | walk_pte[5];
                    if (pte_invalid(walk_pte)) begin
                        walk_page_fault <= 1'b1;
                        ptw_state <= PTW_FAULT;
                    end
                    else if (walk_pte[1] || walk_pte[3]) begin
                        if ((walk_pte[19:10] != 0) ||
                            (walk_is_instr ?
                             !(walk_pte[3] && walk_pte[6] &&
                               ((walk_priv == PRIV_U) ? walk_pte[4] : !walk_pte[4])) :
                             !pte_permission_ok(walk_pte, walk_store, walk_priv,
                                                walk_sum, walk_mxr))) begin
                            walk_page_fault <= 1'b1;
                            ptw_state <= PTW_FAULT;
                        end
                        else begin
                            walk_superpage <= 1'b1;
                            ptw_state <= PTW_FILL;
                        end
                    end
                    else begin
                        walk_pte_addr <= {walk_pte[29:10], 12'b0} +
                                         {20'b0, walk_vaddr[21:12], 2'b0};
                        if ((walk_pte[31:30] != 0) ||
                            (!is_dataram_region({walk_pte[29:10], 12'b0} +
                                                {20'b0, walk_vaddr[21:12], 2'b0}) &&
                             !is_ddr_region({walk_pte[29:10], 12'b0} +
                                            {20'b0, walk_vaddr[21:12], 2'b0}))) begin
                            walk_access_fault <= 1'b1;
                            ptw_state <= PTW_FAULT;
                        end
                        else begin
                            ptw_state <= PTW_L0_WAIT;
                        end
                    end
                end
                PTW_L0_WAIT: begin
                    if (phys_data.ack)
                        ptw_state <= PTW_L0_CAPTURE;
                end
                PTW_L0_CAPTURE: begin
                    walk_pte <= phys_data.dat_r;
                    ptw_state <= PTW_L0_CHECK;
                end
                PTW_L0_CHECK: begin
                    walk_global <= walk_global | walk_pte[5];
                    if (pte_invalid(walk_pte) || !(walk_pte[1] || walk_pte[3]) ||
                        (walk_is_instr ?
                         !(walk_pte[3] && walk_pte[6] &&
                           ((walk_priv == PRIV_U) ? walk_pte[4] : !walk_pte[4])) :
                         !pte_permission_ok(walk_pte, walk_store, walk_priv,
                                            walk_sum, walk_mxr))) begin
                        walk_page_fault <= 1'b1;
                        ptw_state <= PTW_FAULT;
                    end
                    else begin
                        walk_superpage <= 1'b0;
                        ptw_state <= PTW_FILL;
                    end
                end
                PTW_FILL: begin
                    if (walk_is_instr) begin
                        itlb[itlb_replace].valid <= 1'b1;
                        itlb[itlb_replace].global_mapping <= walk_global | walk_pte[5];
                        itlb[itlb_replace].superpage <= walk_superpage;
                        itlb[itlb_replace].asid <= walk_asid;
                        itlb[itlb_replace].vpn <= walk_vaddr[31:12];
                        itlb[itlb_replace].ppn <= walk_pte[31:10];
                        itlb[itlb_replace].u <= walk_pte[4];
                        itlb[itlb_replace].r <= walk_pte[1];
                        itlb[itlb_replace].w <= walk_pte[2];
                        itlb[itlb_replace].x <= walk_pte[3];
                        itlb[itlb_replace].a <= walk_pte[6];
                        itlb[itlb_replace].d <= walk_pte[7];
                        itlb_replace <= itlb_replace + 2'd1;
                    end
                    else begin
                        dtlb[dtlb_replace].valid <= 1'b1;
                        dtlb[dtlb_replace].global_mapping <= walk_global | walk_pte[5];
                        dtlb[dtlb_replace].superpage <= walk_superpage;
                        dtlb[dtlb_replace].asid <= walk_asid;
                        dtlb[dtlb_replace].vpn <= walk_vaddr[31:12];
                        dtlb[dtlb_replace].ppn <= walk_pte[31:10];
                        dtlb[dtlb_replace].u <= walk_pte[4];
                        dtlb[dtlb_replace].r <= walk_pte[1];
                        dtlb[dtlb_replace].w <= walk_pte[2];
                        dtlb[dtlb_replace].x <= walk_pte[3];
                        dtlb[dtlb_replace].a <= walk_pte[6];
                        dtlb[dtlb_replace].d <= walk_pte[7];
                        dtlb_replace <= dtlb_replace + 2'd1;
                    end
                    ptw_state <= PTW_IDLE;
                end
                PTW_FAULT: begin
                    if (walk_is_instr) begin
                        instr_fault_pending <= 1'b1;
                        instr_fault_page <= walk_page_fault;
                        instr_fault_vaddr <= walk_vaddr;
                        ptw_state <= PTW_IDLE;
                    end
                    else if (!d_req_valid_i || (walk_vaddr != d_vaddr_i) ||
                             (walk_store != d_store_i))
                        ptw_state <= PTW_IDLE;
                end
                default: ptw_state <= PTW_IDLE;
            endcase
        end
    end
endmodule

`endif
