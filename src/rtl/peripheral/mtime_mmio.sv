`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"

module mtime_mmio
    (
        input  logic clk,
        input  logic rst_n,
        output logic timer_irq,
        simple_bus_if.slave bus
    );
    import soc_pkg::*;

    logic sel_mtime_lo, sel_mtime_hi, sel_mtimecmp_lo, sel_mtimecmp_hi;
    always_comb begin
        sel_mtime_lo    = (align_word(bus.addr) == IO_MTIME_LO_ADDR);
        sel_mtime_hi    = (align_word(bus.addr) == IO_MTIME_HI_ADDR);
        sel_mtimecmp_lo = (align_word(bus.addr) == IO_MTIMECMP_LO_ADDR);
        sel_mtimecmp_hi = (align_word(bus.addr) == IO_MTIMECMP_HI_ADDR);
    end

    logic [63:0] mtime;
    logic [63:0] mtimecmp;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime <= 64'd0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
        end
        else begin
            mtime <= mtime + 64'd1;

            if (bus.wen && (|bus.wstrb)) begin
                if (sel_mtimecmp_lo) begin
                    mtimecmp[31:0] <= bus.wdata;
                end
                if (sel_mtimecmp_hi) begin
                    mtimecmp[63:32] <= bus.wdata;
                end
            end
        end
    end

    always_comb begin
        bus.rdata = 32'b0;
        if (sel_mtime_lo) begin
            bus.rdata = mtime[31:0];
        end
        else if (sel_mtime_hi) begin
            bus.rdata = mtime[63:32];
        end
        else if (sel_mtimecmp_lo) begin
            bus.rdata = mtimecmp[31:0];
        end
        else if (sel_mtimecmp_hi) begin
            bus.rdata = mtimecmp[63:32];
        end
    end

    assign timer_irq = (mtime >= mtimecmp);

endmodule
