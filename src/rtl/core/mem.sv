`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"
module mem #(
        parameter int unsigned PROGROM_WORDS = soc_pkg::PROGROM_WORDS,
        parameter int unsigned DATARAM_WORDS = soc_pkg::DATARAM_WORDS
    ) (
        input logic clk,
        imem_if.slave instr,
        wb_if.slave data
    );
    import soc_pkg::*;
    localparam int unsigned PROGROM_AW = $clog2(PROGROM_WORDS);
    localparam int unsigned DATARAM_AW = $clog2(DATARAM_WORDS);

    logic [31:0] PROGROM [0:PROGROM_WORDS-1]/*synthesis syn_ramstyle = "block_ram"*/;
    logic [31:0] DATARAM [0:DATARAM_WORDS-1]/*synthesis syn_ramstyle = "block_ram"*/;

    // 字节地址转换为字地址
    logic [PROGROM_AW-1:0] instr_word_addr;
    logic [DATARAM_AW-1:0] data_word_addr;
    assign instr_word_addr = instr.addr[PROGROM_AW+1:2];
    assign data_word_addr  = data.adr[DATARAM_AW+1:2];
    assign instr.stall = 1'b0;
    assign data.stall = 1'b0;

    always_ff @(posedge clk) begin
        if (instr.ren) begin
            instr.rdata <= PROGROM[instr_word_addr];
        end
    end

    always_ff @(posedge clk) begin
        data.ack <= data.cyc && data.stb;

        if (data.cyc && data.stb && !data.we) begin
            data.dat_r <= DATARAM[data_word_addr];
        end

        if (data.cyc && data.stb && data.we && data.sel[0])
            DATARAM[data_word_addr][7:0]   <= data.dat_w[7:0];
        if (data.cyc && data.stb && data.we && data.sel[1])
            DATARAM[data_word_addr][15:8]  <= data.dat_w[15:8];
        if (data.cyc && data.stb && data.we && data.sel[2])
            DATARAM[data_word_addr][23:16] <= data.dat_w[23:16];
        if (data.cyc && data.stb && data.we && data.sel[3])
            DATARAM[data_word_addr][31:24] <= data.dat_w[31:24];
    end

    initial begin
        data.ack = 1'b0;
        data.dat_r = 32'b0;

`ifdef BENCH
        $readmemh("build/PROGROM.hex", PROGROM);
        $readmemh("build/DATARAM.hex", DATARAM);
`else
        $readmemh("../build/PROGROM.hex", PROGROM);
        $readmemh("../build/DATARAM.hex", DATARAM);
`endif

`ifdef BENCH

        $display("[MEM] Initialized PROGROM and DATARAM");
        $display("[MEM] PROGROM[0:3] = %h %h %h %h",
                 PROGROM[0], PROGROM[1], PROGROM[2], PROGROM[3]);
        $display("[MEM] DATARAM[0:3] = %h %h %h %h",
                 DATARAM[0], DATARAM[1], DATARAM[2], DATARAM[3]);
`endif

    end
endmodule
