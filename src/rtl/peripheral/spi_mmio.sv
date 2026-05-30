`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"

module spi_mmio #(
        parameter int unsigned CLK_FREQ_HZ = soc_pkg::CLK_FREQ_HZ,
        parameter int unsigned SPI_DEFAULT_HZ = 200_000
    ) (
        input  logic clk,
        input  logic rst_n,
        wb_if.slave bus,

        output logic spi_cs_n,
        output logic spi_sck,
        output logic spi_mosi,
        input  logic spi_miso
    );
    import soc_pkg::*;
    assign bus.ack = bus.cyc && bus.stb;
    assign bus.stall = 1'b0;

    // ---------------- 寄存器映射 ----------------
    // TXRX   @ IO_SPI_TXRX_ADDR   [7:0]  写：发送字节（TX），读：接收字节（RX）
    // CTRL   @ IO_SPI_CTRL_ADDR:
    //   [0] CS_N（1=释放/拉高，0=选中/拉低）, [1] START（脉冲触发一次传输）
    // STATUS @ IO_SPI_STATUS_ADDR:
    //   [0] BUSY, [1] DONE（粘滞位；在新的 START 时清除）
    // DIV    @ IO_SPI_DIV_ADDR    半周期分频计数（单位：clk 周期，>=1）

    logic sel_txrx, sel_ctrl, sel_status, sel_div;
    always_comb begin
        sel_txrx   = (align_word(bus.adr) == IO_SPI_TXRX_ADDR);
        sel_ctrl   = (align_word(bus.adr) == IO_SPI_CTRL_ADDR);
        sel_status = (align_word(bus.adr) == IO_SPI_STATUS_ADDR);
        sel_div    = (align_word(bus.adr) == IO_SPI_DIV_ADDR);
    end

    // ---------------- MMIO 寄存器 ----------------
    logic [7:0]  tx_reg;
    logic [7:0]  rx_reg;
    logic [15:0] div_reg;
    logic        cs_n_reg;

    logic busy;
    logic done;

    localparam int unsigned DEFAULT_DIV =
               (CLK_FREQ_HZ / (2 * SPI_DEFAULT_HZ)) > 0 ? (CLK_FREQ_HZ / (2 * SPI_DEFAULT_HZ)) : 1;

    logic [15:0] div_eff;
    always_comb begin
        div_eff = (div_reg == 16'd0) ? 16'd1 : div_reg;
    end

    assign spi_cs_n = cs_n_reg;

    // ---------------- SPI 状态机（先发 MSB） ----------------
    logic [7:0] sh_in;
    logic [2:0] bit_idx;
    logic [15:0] div_cnt;
    logic last_rise;

    logic tick;
    always_comb begin
        tick = (div_cnt == 16'd0);
    end

    // 锁存 TX / 分频参数 / CS
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_reg <= 8'hFF;
            div_reg <= DEFAULT_DIV[15:0];
            cs_n_reg <= 1'b1;
        end
        else begin
            if (bus.cyc && bus.stb && bus.we && sel_txrx && (|bus.sel)) begin
                tx_reg <= bus.dat_w[7:0];
            end
            if (bus.cyc && bus.stb && bus.we && sel_div && (|bus.sel)) begin
                div_reg <= bus.dat_w[15:0];
            end
            if (bus.cyc && bus.stb && bus.we && sel_ctrl && (|bus.sel)) begin
                cs_n_reg <= bus.dat_w[0];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            rx_reg <= 8'hFF;

            spi_sck <= 1'b0;
            spi_mosi <= 1'b1;

            sh_in <= 8'h00;
            bit_idx <= 3'd7;
            div_cnt <= 16'd0;
            last_rise <= 1'b0;
        end
        else begin
            if (busy) begin
                if (div_cnt != 16'd0)
                    div_cnt <= div_cnt - 16'd1;
            end

            if (bus.cyc && bus.stb && bus.we && sel_ctrl && (|bus.sel) && bus.dat_w[1] && !busy) begin
                // START：清除粘滞标志，并启动一次传输。
                busy <= 1'b1;
                done <= 1'b0;
                div_cnt <= div_eff;

                spi_sck <= 1'b0;
                spi_mosi <= tx_reg[7];

                sh_in <= 8'h00;
                bit_idx <= 3'd7;
                last_rise <= 1'b0;
            end

            if (busy && tick) begin
                div_cnt <= div_eff;
                if (spi_sck == 1'b0) begin
                    // 上升沿：采样 MISO。
                    spi_sck <= 1'b1;
                    sh_in[bit_idx] <= spi_miso;
                    if (bit_idx == 3'd0)
                        last_rise <= 1'b1;
                end
                else begin
                    // 下降沿：推进到下一位 / 或结束传输。
                    spi_sck <= 1'b0;
                    if (last_rise) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        rx_reg <= sh_in;
                    end
                    else begin
                        bit_idx <= bit_idx - 3'd1;
                        spi_mosi <= tx_reg[bit_idx - 3'd1];
                    end
                end
            end

            if (!busy && !(bus.cyc && bus.stb && bus.we && sel_ctrl && (|bus.sel) && bus.dat_w[1])) begin
                spi_sck <= 1'b0;
            end
        end
    end

    // ---------------- MMIO 读回 ----------------
    logic [31:0] status_rdata;
    always_comb begin
        status_rdata = 32'b0;
        status_rdata[0] = busy;
        status_rdata[1] = done;
    end

    always_comb begin
        if (sel_txrx) begin
            bus.dat_r = {24'b0, rx_reg};
        end
        else if (sel_ctrl) begin
            bus.dat_r = {30'b0, 1'b0, cs_n_reg};
        end
        else if (sel_status) begin
            bus.dat_r = status_rdata;
        end
        else if (sel_div) begin
            bus.dat_r = {16'b0, div_reg};
        end
        else begin
            bus.dat_r = 32'b0;
        end
    end
endmodule
