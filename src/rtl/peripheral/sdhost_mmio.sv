`include "../lib/soc_pkg.sv"
`include "../lib/bus_if.sv"

module sdhost_mmio (
    input  logic clk,
    input  logic rst_n,
    wb_if.slave bus,
    output logic sdclk,
    inout  tri   sdcmd,
    input  logic [3:0] sddat
);
    import soc_pkg::*;

    localparam logic [31:0] ST_BUSY = 32'h0000_0001;
    localparam logic [31:0] ST_DONE = 32'h0000_0002;
    localparam logic [31:0] ST_ERR  = 32'h0000_0004;
    localparam logic [31:0] ST_READ = 32'h0000_0008;

    typedef enum logic [3:0] {
        S_IDLE,
        S_CMD_GAP,
        S_CMD_BITS,
        S_RESP_WAIT,
        S_RESP_BITS,
        S_BUSY_WAIT,
        S_DATA_WAIT,
        S_DATA_BITS,
        S_DATA_CRC,
        S_DATA_END,
        S_DONE
    } state_t;

    state_t state;
    logic [5:0] cmd_idx;
    logic [31:0] cmd_arg;
    logic start_read;
    logic [31:0] status;
    logic [31:0] resp0;
    logic [31:0] data_buf [0:127];
`ifdef BENCH_SD_DIRECT
`ifndef SIM_SD_IMAGE_WORDS
`define SIM_SD_IMAGE_WORDS 8388608
`endif
    localparam integer SIM_SD_IMAGE_ADDR_WIDTH = $clog2(`SIM_SD_IMAGE_WORDS);
    logic [15:0] sim_image [0:`SIM_SD_IMAGE_WORDS-1];
    wire [SIM_SD_IMAGE_ADDR_WIDTH-1:0] sim_base = {
        cmd_arg[SIM_SD_IMAGE_ADDR_WIDTH-9:0], 8'b0
    };
`endif

    logic sdclk_q;
    logic sdcmd_oe;
    logic sdcmd_out;
    logic [7:0] sdclk_div;
    logic [47:0] cmd_shift;
    logic [7:0] bit_count;
    logic [15:0] timeout;
    logic [31:0] resp_shift;
    logic [31:0] data_shift;
    logic [11:0] data_bit_count;
    logic [15:0] data_crc_calc;
    logic [15:0] data_crc_recv;
    logic op_read;
    logic data_started;
    logic data_done;
    logic op_error;
    logic [31:0] debug_status;

`ifdef BENCH
    // Keep all command/data edge transitions in simulation, but do not spend
    // host CPU time reproducing the board's conservative ~200 kHz SD clock.
    localparam logic [7:0] SDCLK_CMD_DIV_MAX = 8'd1;
    localparam logic [7:0] SDCLK_READ_DIV_MAX = 8'd1;
`else
    // Card identification must stay below 400 kHz.  Once initialization has
    // completed, CMD17 may use the card's default-speed mode (up to 25 MHz).
    // With the 27 MHz SoC clock, divider zero produces a 13.5 MHz
    // SD clock and cuts a multi-megabyte Linux load from minutes to seconds.
    localparam logic [7:0] SDCLK_CMD_DIV_MAX = 8'd67;
    localparam logic [7:0] SDCLK_READ_DIV_MAX = 8'd0;
`endif
    wire [7:0] sdclk_div_max = (cmd_idx == 6'd17) ?
                                   SDCLK_READ_DIV_MAX : SDCLK_CMD_DIV_MAX;

    assign sdclk = sdclk_q;
    assign sdcmd = sdcmd_oe ? sdcmd_out : 1'bz;
    assign debug_status = {2'b0, sddat, sdcmd, data_done, data_started, op_read,
                           state, data_bit_count, timeout[5:0]};

`ifdef BENCH_SD_DIRECT
`ifndef SIM_SD_IMAGE_PATH
`define SIM_SD_IMAGE_PATH "program/build/sd_image.hex"
`endif
    initial begin
        $readmemh(`SIM_SD_IMAGE_PATH, sim_image);
    end
`endif

    function automatic logic [6:0] crc7_next(input logic [6:0] crc, input logic bit_in);
        logic inv;
        begin
            inv = bit_in ^ crc[6];
            crc7_next = {crc[5:3], crc[2] ^ inv, crc[1:0], inv};
        end
    endfunction

    function automatic logic [6:0] crc7_cmd(input logic [5:0] cmd, input logic [31:0] arg);
        logic [6:0] crc;
        logic [39:0] payload;
        begin
            crc = 7'b0;
            payload = {2'b01, cmd, arg};
            for (int i = 39; i >= 0; --i)
                crc = crc7_next(crc, payload[i]);
            return crc;
        end
    endfunction

    function automatic logic [15:0] crc16_next(input logic [15:0] crc,
                                                input logic bit_in);
        logic inv;
        begin
            inv = bit_in ^ crc[15];
            crc16_next = {crc[14:12], crc[11] ^ inv, crc[10:5],
                          crc[4] ^ inv, crc[3:0], inv};
        end
    endfunction

    wire [31:0] word_addr = align_word(bus.adr);
    wire data_sel = (word_addr >= IO_SD_DATA_ADDR) && (word_addr < (IO_SD_DATA_ADDR + 32'd512));
    wire [31:0] data_offset = word_addr - IO_SD_DATA_ADDR;
    wire [6:0] data_word = data_offset[8:2];

    always_comb begin
        bus.stall = 1'b0;
        bus.ack = bus.cyc && bus.stb;
        if (word_addr == IO_SD_CMD_ADDR)
            bus.dat_r = {26'b0, cmd_idx};
        else if (word_addr == IO_SD_ARG_ADDR)
            bus.dat_r = cmd_arg;
        else if (word_addr == IO_SD_CTRL_ADDR)
            bus.dat_r = status;
        else if (word_addr == IO_SD_RESP0_ADDR)
            bus.dat_r = resp0;
        else if (word_addr == IO_SD_DEBUG_ADDR)
            bus.dat_r = debug_status;
        else if (word_addr == IO_SD_CRC_ADDR)
            bus.dat_r = {data_crc_recv, data_crc_calc};
        else if (data_sel)
            bus.dat_r = data_buf[data_word];
        else
            bus.dat_r = 32'b0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_idx <= 6'b0;
            cmd_arg <= 32'b0;
            start_read <= 1'b0;
            status <= 32'b0;
        end
        else begin
            start_read <= 1'b0;
            if (bus.cyc && bus.stb && bus.we) begin
                if (word_addr == IO_SD_CMD_ADDR)
                    cmd_idx <= bus.dat_w[5:0];
                else if (word_addr == IO_SD_ARG_ADDR)
                    cmd_arg <= bus.dat_w;
                else if (word_addr == IO_SD_CTRL_ADDR) begin
                    if (bus.dat_w[1])
                        status <= status & ~(ST_DONE | ST_ERR);
                    if (bus.dat_w[0] && ((status & ST_BUSY) == 32'b0)) begin
`ifdef BENCH_SD_DIRECT
                        if (bus.dat_w[3]) begin
                            for (int i = 0; i < 128; ++i) begin
                                data_buf[i] = {
                                    sim_image[sim_base + i * 2][7:0],
                                    sim_image[sim_base + i * 2][15:8],
                                    sim_image[sim_base + i * 2 + 1][7:0],
                                    sim_image[sim_base + i * 2 + 1][15:8]
                                };
                            end
                        end
                        if (cmd_idx == 6'd41)
                            resp0 <= 32'hc0ff8000;
                        else if (cmd_idx == 6'd3)
                            resp0 <= 32'h00130000;
                        else
                            resp0 <= 32'b0;
                        status <= ST_DONE | (bus.dat_w[3] ? ST_READ : 32'b0);
`else
                        start_read <= bus.dat_w[3];
                        status <= ST_BUSY | (bus.dat_w[3] ? ST_READ : 32'b0);
`endif
                    end
                end
            end
            if (state == S_DONE) begin
                status <= (status & ST_READ) | ST_DONE | (op_error ? ST_ERR : 32'b0);
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sdclk_q <= 1'b0;
            sdcmd_oe <= 1'b0;
            sdcmd_out <= 1'b1;
            sdclk_div <= 8'b0;
            cmd_shift <= 48'hffff_ffff_ffff;
            bit_count <= 8'b0;
            timeout <= 16'b0;
            resp0 <= 32'b0;
            resp_shift <= 32'b0;
            data_shift <= 32'b0;
            data_bit_count <= 12'b0;
            data_crc_calc <= 16'b0;
            data_crc_recv <= 16'b0;
            op_read <= 1'b0;
            data_started <= 1'b0;
            data_done <= 1'b0;
            op_error <= 1'b0;
            state <= S_IDLE;
            for (int i = 0; i < 128; ++i)
                data_buf[i] = 32'b0;
        end
        else begin
            if (sdclk_div != sdclk_div_max) begin
                sdclk_div <= sdclk_div + 8'd1;
            end
            else begin
                sdclk_div <= 8'd0;
                sdclk_q <= ~sdclk_q;

                if (sdclk_q) begin
                unique case (state)
                    S_IDLE: begin
                        sdcmd_oe <= 1'b0;
                        sdcmd_out <= 1'b1;
                        if (start_read || (((status & ST_BUSY) != 32'b0) && ((status & ST_DONE) == 32'b0))) begin
                            cmd_shift <= {2'b01, cmd_idx, cmd_arg, crc7_cmd(cmd_idx, cmd_arg), 1'b1};
                            bit_count <= (cmd_idx == 6'd0) ? 8'd80 : 8'd8;
                            timeout <= 16'b0;
                            resp0 <= 32'b0;
                            op_read <= start_read || ((status & ST_READ) != 32'b0);
                            data_started <= 1'b0;
                            data_done <= 1'b0;
                            data_crc_calc <= 16'b0;
                            data_crc_recv <= 16'b0;
                            op_error <= 1'b0;
                            state <= S_CMD_GAP;
                        end
                    end
                    S_CMD_GAP: begin
                        sdcmd_oe <= 1'b1;
                        sdcmd_out <= 1'b1;
                        bit_count <= bit_count - 8'd1;
                        if (bit_count == 8'd1) begin
                            bit_count <= 8'd48;
                            state <= S_CMD_BITS;
                        end
                    end
                    S_CMD_BITS: begin
                        sdcmd_oe <= 1'b1;
                        sdcmd_out <= cmd_shift[47];
                        cmd_shift <= {cmd_shift[46:0], 1'b1};
                        bit_count <= bit_count - 8'd1;
                        if (bit_count == 8'd1) begin
                            sdcmd_oe <= 1'b0;
                            if (cmd_idx == 6'd0)
                                state <= S_DONE;
                            else begin
                                timeout <= 16'b0;
                                bit_count <= (cmd_idx == 6'd2) ? 8'd136 : 8'd48;
                                resp0 <= 32'b0;
                                state <= S_RESP_WAIT;
                            end
                        end
                    end
                    S_DONE: state <= S_IDLE;
                    default: ;
                endcase
                end
                else begin
                unique case (state)
                    S_RESP_WAIT: begin
                        timeout <= timeout + 16'd1;
                        if (sdcmd == 1'b0) begin
                            bit_count <= bit_count - 8'd1;
                            state <= S_RESP_BITS;
                        end
                        else if (timeout == 16'hffff)
                        begin
                            op_error <= 1'b1;
                            state <= S_DONE;
                        end
                    end
                    S_RESP_BITS: begin
                        bit_count <= bit_count - 8'd1;
                        if (bit_count <= 8'd40 && bit_count >= 8'd9)
                            resp0 <= {resp0[30:0], sdcmd};
                        if (bit_count == 8'd1) begin
                            if (op_read) begin
                                timeout <= 16'b0;
                                data_bit_count <= 12'b0;
                                state <= S_DATA_WAIT;
                            end
                            else if (cmd_idx == 6'd7) begin
                                timeout <= 16'b0;
                                bit_count <= 8'd8;
                                state <= S_BUSY_WAIT;
                            end
                            else
                                state <= S_DONE;
                        end
                    end
                    S_BUSY_WAIT: begin
                        timeout <= timeout + 16'd1;
                        if (sddat[0] == 1'b0) begin
                            bit_count <= 8'd8;
                        end
                        else if (bit_count == 8'd1) begin
                            state <= S_DONE;
                        end
                        else begin
                            bit_count <= bit_count - 8'd1;
                        end
                        if (timeout == 16'hffff) begin
                            op_error <= 1'b1;
                            state <= S_DONE;
                        end
                    end
                    S_DATA_WAIT: begin
                        timeout <= timeout + 16'd1;
                        if (sddat[0] == 1'b0) begin
                            data_started <= 1'b1;
                            data_bit_count <= 12'd0;
                            data_shift <= 32'b0;
                            data_crc_calc <= 16'b0;
                            data_crc_recv <= 16'b0;
                            state <= S_DATA_BITS;
                        end
                        else if (timeout == 16'hffff) begin
                            op_error <= 1'b1;
                            state <= S_DONE;
                        end
                    end
                    S_DATA_BITS: begin
                        data_shift <= {data_shift[30:0], sddat[0]};
                        data_crc_calc <= crc16_next(data_crc_calc, sddat[0]);
                        data_bit_count <= data_bit_count + 12'd1;
                        if (data_bit_count[4:0] == 5'd31)
                            data_buf[data_bit_count[11:5]] <= {data_shift[30:0], sddat[0]};
                        if (data_bit_count == 12'd4095) begin
                            data_done <= 1'b1;
                            bit_count <= 8'd16;
                            state <= S_DATA_CRC;
                        end
                    end
                    S_DATA_CRC: begin
                        data_crc_recv <= {data_crc_recv[14:0], sddat[0]};
                        bit_count <= bit_count - 8'd1;
                        if (bit_count == 8'd1)
                            state <= S_DATA_END;
                    end
                    S_DATA_END: begin
                        if ((sddat[0] != 1'b1) ||
                            (data_crc_recv != data_crc_calc))
                            op_error <= 1'b1;
                        state <= S_DONE;
                    end
                    default: ;
                endcase
                end
            end
        end
    end
endmodule
