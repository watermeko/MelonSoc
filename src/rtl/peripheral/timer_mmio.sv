`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"

module timer_mmio
    (
        input  logic clk,
        input  logic rst_n,
        output logic timer_irq,
        simple_bus_if.slave bus
    );
    import soc_pkg::*;

    // ---------------- 寄存器映射 ----------------
    // CTRL   @ IO_TIMER_CTRL_ADDR
    //   [0] EN, [1] ARMED, [2] PERIODIC, [3] PRESC_EN, [8] IRQ_EN（预留/未来使用）, [31] SOFT_RESET（自清零）
    // PRESC  @ IO_TIMER_PRESC_ADDR   预分频值；当 PRESC_EN=1 时，每 (PRESC+1) 个 clk 周期产生一次 tick
    // COUNT  @ IO_TIMER_COUNT_ADDR   自由运行递增计数器（可读/可写）
    // CMP    @ IO_TIMER_CMP_ADDR     比较值（可读/可写）
    // PERIOD @ IO_TIMER_PERIOD_ADDR  周期模式下：每次匹配后对 CMP 增加该步进值（可读/可写）
    // STATUS @ IO_TIMER_STATUS_ADDR
    //   [0] PENDING（粘滞位，写 1 清除 / W1C）

    logic sel_ctrl, sel_presc, sel_count, sel_cmp, sel_period, sel_status;
    always_comb begin
        sel_ctrl   = (align_word(bus.addr) == IO_TIMER_CTRL_ADDR);
        sel_presc  = (align_word(bus.addr) == IO_TIMER_PRESC_ADDR);
        sel_count  = (align_word(bus.addr) == IO_TIMER_COUNT_ADDR);
        sel_cmp    = (align_word(bus.addr) == IO_TIMER_CMP_ADDR);
        sel_period = (align_word(bus.addr) == IO_TIMER_PERIOD_ADDR);
        sel_status = (align_word(bus.addr) == IO_TIMER_STATUS_ADDR);
    end

    logic        ctrl_en;
    logic        ctrl_armed;
    logic        ctrl_periodic;
    logic        ctrl_presc_en;
    logic        ctrl_irq_en;

    logic [31:0] presc_reg;
    logic [31:0] count_reg;
    logic [31:0] cmp_reg;
    logic [31:0] period_reg;

    logic        pending;
    logic [31:0] presc_cnt;

    logic tick;
    always_comb begin
        if (!ctrl_en) begin
            tick = 1'b0;
        end
        else if (!ctrl_presc_en) begin
            tick = 1'b1;
        end
        else begin
            tick = (presc_cnt >= presc_reg);
        end
    end

    // ---------------- Registers + timer core ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_en       <= 1'b0;
            ctrl_armed    <= 1'b0;
            ctrl_periodic <= 1'b0;
            ctrl_presc_en <= 1'b0;
            ctrl_irq_en   <= 1'b0;

            presc_reg  <= 32'd0;
            presc_cnt  <= 32'd0;
            count_reg  <= 32'd0;
            cmp_reg    <= 32'd0;
            period_reg <= 32'd0;

            pending <= 1'b0;
        end
        else begin
            // MMIO writes
            if (bus.wen && (|bus.wstrb)) begin
                if (sel_ctrl) begin
                    ctrl_en       <= bus.wdata[0];
                    ctrl_armed    <= bus.wdata[1];
                    ctrl_periodic <= bus.wdata[2];
                    ctrl_presc_en <= bus.wdata[3];
                    ctrl_irq_en   <= bus.wdata[8];

                    if (bus.wdata[31]) begin
                        // 软复位：清除定时器状态与粘滞标志位。
                        ctrl_en       <= 1'b0;
                        ctrl_armed    <= 1'b0;
                        ctrl_periodic <= 1'b0;
                        ctrl_presc_en <= 1'b0;
                        ctrl_irq_en   <= 1'b0;

                        presc_reg  <= 32'd0;
                        presc_cnt  <= 32'd0;
                        count_reg  <= 32'd0;
                        cmp_reg    <= 32'd0;
                        period_reg <= 32'd0;
                        pending    <= 1'b0;
                    end
                end

                if (sel_presc) begin
                    presc_reg <= bus.wdata;
                    presc_cnt <= 32'd0;
                end

                if (sel_count) begin
                    count_reg <= bus.wdata;
                end

                if (sel_period) begin
                    period_reg <= bus.wdata;
                end

                if (sel_cmp) begin
                    cmp_reg <= bus.wdata;

                    // 如果新写入的 CMP 已经落后于当前计数，则立即置位 pending。
                    if (ctrl_en && ctrl_armed && (count_reg >= bus.wdata)) begin
                        pending <= 1'b1;
                    end
                end

                if (sel_status) begin
                    // PENDING：写 1 清除（W1C）
                    if (bus.wdata[0]) begin
                        pending <= 1'b0;
                    end
                end
            end

            // 预分频 / 计数器更新
            if (ctrl_en) begin
                if (!ctrl_presc_en) begin
                    presc_cnt <= 32'd0;
                end
                else if (tick) begin
                    presc_cnt <= 32'd0;
                end
                else begin
                    presc_cnt <= presc_cnt + 32'd1;
                end

                if (tick) begin
                    count_reg <= count_reg + 32'd1;

                    if (ctrl_armed && ((count_reg + 32'd1) == cmp_reg)) begin
                        pending <= 1'b1;
                        if (ctrl_periodic) begin
                            cmp_reg <= cmp_reg + period_reg;
                        end
                        else begin
                            ctrl_armed <= 1'b0;
                        end
                    end
                end
            end
            else begin
                presc_cnt <= 32'd0;
            end
        end
    end

    // ---------------- MMIO 读回 ----------------
    always_comb begin
        bus.rdata = 32'b0;

        if (sel_ctrl) begin
            bus.rdata[0]  = ctrl_en;
            bus.rdata[1]  = ctrl_armed;
            bus.rdata[2]  = ctrl_periodic;
            bus.rdata[3]  = ctrl_presc_en;
            bus.rdata[8]  = ctrl_irq_en;
            bus.rdata[31] = 1'b0;
        end
        else if (sel_presc) begin
            bus.rdata = presc_reg;
        end
        else if (sel_count) begin
            bus.rdata = count_reg;
        end
        else if (sel_cmp) begin
            bus.rdata = cmp_reg;
        end
        else if (sel_period) begin
            bus.rdata = period_reg;
        end
        else if (sel_status) begin
            bus.rdata[0] = pending;
        end
    end
    
    assign timer_irq = pending & ctrl_irq_en;

endmodule

