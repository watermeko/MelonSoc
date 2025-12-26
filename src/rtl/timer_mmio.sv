`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"

module timer_mmio #(
  parameter int unsigned XLEN = soc_pkg::XLEN
) (
  input  logic clk,
  input  logic rst_n,
  simple_bus_if.slave bus
);
  import soc_pkg::*;

  // ---------------- Register map ----------------
  // CTRL   @ IO_TIMER_CTRL_ADDR
  //   [0] EN, [1] ARMED, [2] PERIODIC, [3] PRESC_EN, [8] IRQ_EN (future), [31] SOFT_RESET (self-clearing)
  // PRESC  @ IO_TIMER_PRESC_ADDR   prescaler value, tick every (PRESC+1) cycles when PRESC_EN=1
  // COUNT  @ IO_TIMER_COUNT_ADDR   free-running up-counter (read/write)
  // CMP    @ IO_TIMER_CMP_ADDR     compare value (read/write)
  // PERIOD @ IO_TIMER_PERIOD_ADDR  periodic increment applied to CMP on match (read/write)
  // STATUS @ IO_TIMER_STATUS_ADDR
  //   [0] PENDING (sticky, W1C)

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
    end else if (!ctrl_presc_en) begin
      tick = 1'b1;
    end else begin
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
    end else begin
      // MMIO writes
      if (bus.wen && (|bus.wstrb)) begin
        if (sel_ctrl) begin
          ctrl_en       <= bus.wdata[0];
          ctrl_armed    <= bus.wdata[1];
          ctrl_periodic <= bus.wdata[2];
          ctrl_presc_en <= bus.wdata[3];
          ctrl_irq_en   <= bus.wdata[8];

          if (bus.wdata[31]) begin
            // Soft reset: clear timer state and sticky flags.
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

          // If the new CMP is already in the past, assert pending immediately.
          if (ctrl_en && ctrl_armed && (count_reg >= bus.wdata)) begin
            pending <= 1'b1;
          end
        end

        if (sel_status) begin
          // W1C PENDING
          if (bus.wdata[0]) begin
            pending <= 1'b0;
          end
        end
      end

      // Prescaler / counter update
      if (ctrl_en) begin
        if (!ctrl_presc_en) begin
          presc_cnt <= 32'd0;
        end else if (tick) begin
          presc_cnt <= 32'd0;
        end else begin
          presc_cnt <= presc_cnt + 32'd1;
        end

        if (tick) begin
          count_reg <= count_reg + 32'd1;

          // Compare match on the updated count value.
          if (ctrl_armed && ((count_reg + 32'd1) == cmp_reg)) begin
            pending <= 1'b1;
            if (ctrl_periodic) begin
              cmp_reg <= cmp_reg + period_reg;
            end else begin
              ctrl_armed <= 1'b0;
            end
          end
        end
      end else begin
        presc_cnt <= 32'd0;
      end
    end
  end

  // ---------------- MMIO readback ----------------
  always_comb begin
    bus.rdata = 32'b0;

    if (sel_ctrl) begin
      bus.rdata[0]  = ctrl_en;
      bus.rdata[1]  = ctrl_armed;
      bus.rdata[2]  = ctrl_periodic;
      bus.rdata[3]  = ctrl_presc_en;
      bus.rdata[8]  = ctrl_irq_en;
      bus.rdata[31] = 1'b0;
    end else if (sel_presc) begin
      bus.rdata = presc_reg;
    end else if (sel_count) begin
      bus.rdata = count_reg;
    end else if (sel_cmp) begin
      bus.rdata = cmp_reg;
    end else if (sel_period) begin
      bus.rdata = period_reg;
    end else if (sel_status) begin
      bus.rdata[0] = pending;
    end
  end
endmodule

