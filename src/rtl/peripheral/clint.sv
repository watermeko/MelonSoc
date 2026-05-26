// Standard SiFive CLINT (Core Local Interruptor) for RV32 with 1 hart.
//
// Register layout (offsets from CLINT base):
//   0x0000  MSIP[0]         — Machine Software Interrupt Pending (hart 0)
//   0x4000  MTIMECMP[0].lo  — Machine Timer Compare (hart 0), low 32 bits
//   0x4004  MTIMECMP[0].hi  — Machine Timer Compare (hart 0), high 32 bits
//   0xBFF8  MTIME.lo        — Machine Timer, low 32 bits (read-only)
//   0xBFFC  MTIME.hi        — Machine Timer, high 32 bits (read-only)
//
// Writes to mtime/MTIME are ignored.  To set a timer interrupt, write
// the 64-bit compare value low-word first then high-word; the high-word
// write commits the comparison.  mtime increments every clock cycle.

`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"

module clint (
    input  logic clk,
    input  logic rst_n,
    output logic timer_irq,
    output logic sw_irq,
    simple_bus_if.slave bus
);
    import soc_pkg::*;

    // ---- address decode (offset from CLINT base) ---------------------------
    logic [31:0] offset;
    logic sel_msip, sel_mtimecmp_lo, sel_mtimecmp_hi, sel_mtime_lo, sel_mtime_hi;

    assign offset = bus.addr - IO_CLINT_BASE_ADDR;

    always_comb begin
        sel_msip        = (offset == 32'h0000_0000);
        sel_mtimecmp_lo = (offset == 32'h0000_4000);
        sel_mtimecmp_hi = (offset == 32'h0000_4004);
        sel_mtime_lo    = (offset == 32'h0000_BFF8);
        sel_mtime_hi    = (offset == 32'h0000_BFFC);
    end

    // ---- MSIP register -----------------------------------------------------
    logic msip_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msip_reg <= 1'b0;
        end else begin
            if (bus.wen && (|bus.wstrb) && sel_msip) begin
                msip_reg <= bus.wdata[0];
            end
        end
    end

    assign sw_irq = msip_reg;

    // ---- MTIME 64-bit counter & MTIMECMP compare register ------------------
    logic [63:0] mtime;
    logic [63:0] mtimecmp;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime    <= 64'd0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
        end else begin
            mtime <= mtime + 64'd1;

            if (bus.wen && (|bus.wstrb)) begin
                if (sel_mtimecmp_lo)
                    mtimecmp[31:0]  <= bus.wdata;
                if (sel_mtimecmp_hi)
                    mtimecmp[63:32] <= bus.wdata;
            end
        end
    end

    // ---- read-data mux -----------------------------------------------------
    always_comb begin
        bus.rdata = 32'b0;
        if (sel_msip)
            bus.rdata = {31'b0, msip_reg};
        else if (sel_mtimecmp_lo)
            bus.rdata = mtimecmp[31:0];
        else if (sel_mtimecmp_hi)
            bus.rdata = mtimecmp[63:32];
        else if (sel_mtime_lo)
            bus.rdata = mtime[31:0];
        else if (sel_mtime_hi)
            bus.rdata = mtime[63:32];
    end

    // ---- interrupt generation ----------------------------------------------
    assign timer_irq = (mtime >= mtimecmp);

endmodule
