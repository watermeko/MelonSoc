`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"

// 地址: IO_MSIP_ADDR (0x400070)
//   写 bit[0] = 1 → 置位软件中断 (sw_irq = 1)
//   写 bit[0] = 0 → 清除软件中断 (sw_irq = 0)
//   读         → {31'b0, msip_reg} 返回当前状态

module msip_mmio (
    input  logic clk,
    input  logic rst_n,
    output logic sw_irq,
    simple_bus_if.slave bus
);
    import soc_pkg::*;

    logic sel_msip;
    always_comb begin
        sel_msip = (align_word(bus.addr) == IO_MSIP_ADDR);
    end

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

    always_comb begin
        bus.rdata = 32'b0;
        if (sel_msip) begin
            bus.rdata = {31'b0, msip_reg};
        end
    end

    assign sw_irq = msip_reg;

endmodule
