`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"
`include "core/priv_csr.sv"
`include "core/sv32_mmu.sv"
`include "core/cpu.sv"
`include "core/mem.sv"
`include "include/peripherals.sv"
`ifdef BENCH
`include "../sim/sd_fake.v"
`endif
module SOC (
        input  logic clk,
        input  logic ddr_app_clk,
        input  logic rst_n,
        output logic [5:0] leds,
        input  logic rxd,
        output logic txd,

        inout  tri   i2c_scl,
        inout  tri   i2c_sda,

        output logic spi_cs_n,
        output logic spi_sck,
        output logic spi_mosi,
        input  logic spi_miso,
        output logic sdclk,
        inout  tri   sdcmd,
        inout  tri [3:0] sddat,

        output logic [27:0] ddr_app_addr,
        output logic        ddr_app_cmd_en,
        output logic [2:0]  ddr_app_cmd,
        input  logic        ddr_app_cmd_rdy,

        output logic        ddr_app_wren,
        output logic        ddr_app_data_end,
        output logic [127:0] ddr_app_data,
        input  logic         ddr_app_data_rdy,

        input  logic         ddr_app_rdata_valid,
        input  logic         ddr_app_rdata_end,
        input  logic [127:0] ddr_app_rdata,

        input  logic         ddr_init_calib_complete,
         output logic [5:0]   ddr_app_burst_number,
         output logic         ddr_app_idle,    // CPU DDR bridge APP FSM idle
         output logic         ddr_app_lock,
         output logic         write_commit_valid,
         output logic [31:0]  write_commit_addr,
         output logic [3:0]   write_commit_sel
    );
    import soc_pkg::*;

`ifdef BENCH
    // The physical SD socket provides pull-ups.  Model them explicitly;
    // otherwise Verilator's two-state handling turns an undriven CMD/DAT
    // line into zero and creates false response/data start bits.
    pullup(sdcmd);
    pullup(sddat[0]);
    pullup(sddat[1]);
    pullup(sddat[2]);
    pullup(sddat[3]);
`endif

    imem_if instr_bus();
    imem_if instr_rom_bus();
    wb_if cpu_data_bus();
    wb_if ram_bus();
    wb_if mmio_bus();
    wb_if ddr_bus();
    wb_if ddr_data_bus();
    wb_if ddr_instr_bus();

    wb_if mmio_gpio_bus();
    wb_if mmio_uart_bus();
    wb_if mmio_i2c_bus();
    wb_if mmio_timer_bus();
    wb_if mmio_spi_bus();
    wb_if mmio_sd_bus();
    wb_if mmio_clint_bus();

    logic ext_write_valid;
    logic [31:0] ext_write_addr;
    logic [3:0] ext_write_sel;

    assign ext_write_valid = 1'b0;
    assign ext_write_addr = 32'b0;
    assign ext_write_sel = 4'b0;

    cpu u_cpu (
            .clk(clk),
            .rst_n(rst_n),
            .ext_irq(timer_irq),
            .sw_irq(clint_sw_irq),
            .timer_irq(clint_timer_irq),
            .ext_write_valid(ext_write_valid),
            .ext_write_addr(ext_write_addr),
            .ext_write_sel(ext_write_sel),
            .instr(instr_bus),
            .data(cpu_data_bus)
        );

    mem u_mem (
            .clk(clk),
            .instr(instr_rom_bus),
            .data(ram_bus)
        );

    logic instr_is_ddr;
    logic instr_ddr_pending;
    logic instr_ddr_killed;
    logic [31:0] instr_ddr_addr;
    logic [31:0] instr_ddr_rdata_q;
    always_comb begin
        instr_is_ddr = is_ddr_region(instr_bus.addr);

        instr_rom_bus.addr = instr_bus.addr;
        instr_rom_bus.ren = instr_bus.ren && !instr_is_ddr;
        instr_rom_bus.flush = instr_bus.flush;
        instr_bus.rdata = instr_is_ddr ?
                          ((ddr_instr_bus.ack && instr_ddr_pending &&
                            !instr_ddr_killed && !instr_bus.flush) ?
                           ddr_instr_bus.dat_r : instr_ddr_rdata_q) :
                          instr_rom_bus.rdata;
        instr_bus.stall = instr_is_ddr ?
                          !(ddr_instr_bus.ack && instr_ddr_pending &&
                            !instr_ddr_killed && !instr_bus.flush &&
                            (instr_bus.addr == instr_ddr_addr)) :
                          instr_rom_bus.stall;

        ddr_instr_bus.adr = instr_ddr_pending ? instr_ddr_addr : instr_bus.addr;
        ddr_instr_bus.dat_w = 32'b0;
        ddr_instr_bus.sel = 4'b1111;
        ddr_instr_bus.we = 1'b0;
        ddr_instr_bus.lock = 1'b0;
        ddr_instr_bus.cyc = instr_ddr_pending || (instr_bus.ren && instr_is_ddr);
        ddr_instr_bus.stb = ddr_instr_bus.cyc;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            instr_ddr_pending <= 1'b0;
            instr_ddr_killed <= 1'b0;
            instr_ddr_addr <= 32'b0;
            instr_ddr_rdata_q <= 32'b0;
        end
        else if (ddr_instr_bus.ack) begin
            instr_ddr_pending <= 1'b0;
            instr_ddr_killed <= 1'b0;
            if (!instr_ddr_killed && !instr_bus.flush)
                instr_ddr_rdata_q <= ddr_instr_bus.dat_r;
        end
        else if (instr_bus.flush && instr_ddr_pending) begin
            instr_ddr_killed <= 1'b1;
        end
        else if (!instr_ddr_pending && instr_bus.ren && instr_is_ddr) begin
            instr_ddr_pending <= 1'b1;
            instr_ddr_killed <= 1'b0;
            instr_ddr_addr <= instr_bus.addr;
        end
    end

    logic data_is_mmio;
    logic data_is_ddr;
    logic data_is_ram;
    logic data_unmapped;
    logic unmapped_ack_q;
    logic mmio_ack_q;
    logic [31:0] cpu_data_rdata_mux;
    logic [31:0] cpu_data_rdata_q;
    always_comb begin
        data_is_mmio = is_mapped_mmio(cpu_data_bus.adr);
        data_is_ddr = is_ddr_region(cpu_data_bus.adr);
        data_is_ram = is_dataram_region(cpu_data_bus.adr);
        data_unmapped = cpu_data_bus.cyc && cpu_data_bus.stb &&
                        !is_mapped_data_address(cpu_data_bus.adr);

        ram_bus.adr   = cpu_data_bus.adr;
        ram_bus.dat_w = cpu_data_bus.dat_w;
        ram_bus.sel   = cpu_data_bus.sel;
        ram_bus.we    = cpu_data_bus.we;
        ram_bus.lock  = cpu_data_bus.lock;
        ram_bus.cyc   = cpu_data_bus.cyc && data_is_ram && !data_unmapped;
        ram_bus.stb   = cpu_data_bus.stb && data_is_ram && !data_unmapped;

        mmio_bus.adr   = cpu_data_bus.adr;
        mmio_bus.dat_w = cpu_data_bus.dat_w;
        mmio_bus.sel   = cpu_data_bus.sel;
        mmio_bus.we    = cpu_data_bus.we;
        mmio_bus.lock  = cpu_data_bus.lock;
        mmio_bus.cyc   = cpu_data_bus.cyc && data_is_mmio;
        mmio_bus.stb   = cpu_data_bus.stb && data_is_mmio;

        ddr_data_bus.adr   = cpu_data_bus.adr;
        ddr_data_bus.dat_w = cpu_data_bus.dat_w;
        ddr_data_bus.sel   = cpu_data_bus.sel;
        ddr_data_bus.we    = cpu_data_bus.we;
        ddr_data_bus.lock  = cpu_data_bus.lock;
        ddr_data_bus.cyc   = cpu_data_bus.cyc && data_is_ddr;
        ddr_data_bus.stb   = cpu_data_bus.stb && data_is_ddr;
    end

    always_comb begin
        unique case (1'b1)
            data_is_mmio: begin
                cpu_data_rdata_mux = mmio_bus.dat_r;
                cpu_data_bus.ack = mmio_bus.ack;
                cpu_data_bus.stall = mmio_bus.stall;
            end
            data_is_ddr: begin
                cpu_data_rdata_mux = ddr_data_bus.dat_r;
                cpu_data_bus.ack = ddr_data_bus.ack;
                cpu_data_bus.stall = ddr_data_bus.stall;
            end
            data_unmapped: begin
                cpu_data_rdata_mux = 32'b0;
                cpu_data_bus.ack = unmapped_ack_q;
                cpu_data_bus.stall = 1'b0;
            end
            default: begin
                cpu_data_rdata_mux = ram_bus.dat_r;
                cpu_data_bus.ack = ram_bus.ack;
                cpu_data_bus.stall = ram_bus.stall;
            end
        endcase

        cpu_data_bus.dat_r = cpu_data_bus.ack ? cpu_data_rdata_mux :
                                                cpu_data_rdata_q;
    end

    assign ddr_app_lock = ddr_data_bus.lock;
    assign write_commit_valid = cpu_data_bus.cyc && cpu_data_bus.stb && cpu_data_bus.ack && cpu_data_bus.we;
    assign write_commit_addr = cpu_data_bus.adr;
    assign write_commit_sel = cpu_data_bus.sel;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_data_rdata_q <= 32'b0;
            unmapped_ack_q <= 1'b0;
            mmio_ack_q <= 1'b0;
        end
        else begin
            unmapped_ack_q <= data_unmapped && !unmapped_ack_q;
            mmio_ack_q <= mmio_bus.cyc && mmio_bus.stb && !mmio_ack_q;
            if (cpu_data_bus.cyc && cpu_data_bus.stb && cpu_data_bus.ack)
                cpu_data_rdata_q <= cpu_data_rdata_mux;
        end
    end

    logic sel_leds;
    logic sel_uart;
    logic sel_i2c;
    logic sel_timer;
    logic sel_spi;
    logic sel_sd;
    logic sel_clint;

    always_comb begin
        sel_leds = (align_word(mmio_bus.adr) == IO_LEDS_ADDR);
        sel_uart = (align_word(mmio_bus.adr) == IO_UART_DAT_ADDR) ||
                   (align_word(mmio_bus.adr) == IO_UART_CTRL_ADDR);
        sel_i2c  = (align_word(mmio_bus.adr) == IO_I2C_TXRX_ADDR) ||
                   (align_word(mmio_bus.adr) == IO_I2C_CMD_ADDR) ||
                   (align_word(mmio_bus.adr) == IO_I2C_STATUS_ADDR) ||
                   (align_word(mmio_bus.adr) == IO_I2C_DIV_ADDR);
        sel_timer = (align_word(mmio_bus.adr) == IO_TIMER_CTRL_ADDR) ||
                    (align_word(mmio_bus.adr) == IO_TIMER_PRESC_ADDR) ||
                    (align_word(mmio_bus.adr) == IO_TIMER_COUNT_ADDR) ||
                    (align_word(mmio_bus.adr) == IO_TIMER_CMP_ADDR) ||
                    (align_word(mmio_bus.adr) == IO_TIMER_PERIOD_ADDR) ||
                    (align_word(mmio_bus.adr) == IO_TIMER_STATUS_ADDR);
        sel_spi = (align_word(mmio_bus.adr) == IO_SPI_TXRX_ADDR) ||
                  (align_word(mmio_bus.adr) == IO_SPI_CTRL_ADDR) ||
                  (align_word(mmio_bus.adr) == IO_SPI_STATUS_ADDR) ||
                  (align_word(mmio_bus.adr) == IO_SPI_DIV_ADDR);
        sel_sd = (align_word(mmio_bus.adr) == IO_SD_CMD_ADDR) ||
                 (align_word(mmio_bus.adr) == IO_SD_ARG_ADDR) ||
                 (align_word(mmio_bus.adr) == IO_SD_CTRL_ADDR) ||
                 (align_word(mmio_bus.adr) == IO_SD_RESP0_ADDR) ||
                 (align_word(mmio_bus.adr) == IO_SD_DEBUG_ADDR) ||
                 (align_word(mmio_bus.adr) == IO_SD_CRC_ADDR) ||
                 ((align_word(mmio_bus.adr) >= IO_SD_DATA_ADDR) &&
                  (align_word(mmio_bus.adr) < (IO_SD_DATA_ADDR + 32'd512)));
        sel_clint = (align_word(mmio_bus.adr) == IO_CLINT_MSIP_ADDR) ||
                    (align_word(mmio_bus.adr) == IO_CLINT_MTIMECMP_ADDR) ||
                    (align_word(mmio_bus.adr) == (IO_CLINT_MTIMECMP_ADDR + 4)) ||
                    (align_word(mmio_bus.adr) == IO_CLINT_MTIME_ADDR) ||
                    (align_word(mmio_bus.adr) == (IO_CLINT_MTIME_ADDR + 4));

        mmio_gpio_bus.adr   = mmio_bus.adr;
        mmio_gpio_bus.dat_w = mmio_bus.dat_w;
        mmio_gpio_bus.sel   = mmio_bus.sel;
        mmio_gpio_bus.we    = mmio_bus.we;
        mmio_gpio_bus.lock  = mmio_bus.lock;
        mmio_gpio_bus.cyc   = mmio_bus.cyc && sel_leds && !mmio_ack_q;
        mmio_gpio_bus.stb   = mmio_bus.stb && sel_leds && !mmio_ack_q;

        mmio_uart_bus.adr   = mmio_bus.adr;
        mmio_uart_bus.dat_w = mmio_bus.dat_w;
        mmio_uart_bus.sel   = mmio_bus.sel;
        mmio_uart_bus.we    = mmio_bus.we;
        mmio_uart_bus.lock  = mmio_bus.lock;
        mmio_uart_bus.cyc   = mmio_bus.cyc && sel_uart && !mmio_ack_q;
        mmio_uart_bus.stb   = mmio_bus.stb && sel_uart && !mmio_ack_q;

        mmio_i2c_bus.adr   = mmio_bus.adr;
        mmio_i2c_bus.dat_w = mmio_bus.dat_w;
        mmio_i2c_bus.sel   = mmio_bus.sel;
        mmio_i2c_bus.we    = mmio_bus.we;
        mmio_i2c_bus.lock  = mmio_bus.lock;
        mmio_i2c_bus.cyc   = mmio_bus.cyc && sel_i2c && !mmio_ack_q;
        mmio_i2c_bus.stb   = mmio_bus.stb && sel_i2c && !mmio_ack_q;

        mmio_timer_bus.adr   = mmio_bus.adr;
        mmio_timer_bus.dat_w = mmio_bus.dat_w;
        mmio_timer_bus.sel   = mmio_bus.sel;
        mmio_timer_bus.we    = mmio_bus.we;
        mmio_timer_bus.lock  = mmio_bus.lock;
        mmio_timer_bus.cyc   = mmio_bus.cyc && sel_timer && !mmio_ack_q;
        mmio_timer_bus.stb   = mmio_bus.stb && sel_timer && !mmio_ack_q;

        mmio_spi_bus.adr   = mmio_bus.adr;
        mmio_spi_bus.dat_w = mmio_bus.dat_w;
        mmio_spi_bus.sel   = mmio_bus.sel;
        mmio_spi_bus.we    = mmio_bus.we;
        mmio_spi_bus.lock  = mmio_bus.lock;
        mmio_spi_bus.cyc   = mmio_bus.cyc && sel_spi && !mmio_ack_q;
        mmio_spi_bus.stb   = mmio_bus.stb && sel_spi && !mmio_ack_q;

        mmio_sd_bus.adr   = mmio_bus.adr;
        mmio_sd_bus.dat_w = mmio_bus.dat_w;
        mmio_sd_bus.sel   = mmio_bus.sel;
        mmio_sd_bus.we    = mmio_bus.we;
        mmio_sd_bus.lock  = mmio_bus.lock;
        mmio_sd_bus.cyc   = mmio_bus.cyc && sel_sd && !mmio_ack_q;
        mmio_sd_bus.stb   = mmio_bus.stb && sel_sd && !mmio_ack_q;

        mmio_clint_bus.adr   = mmio_bus.adr;
        mmio_clint_bus.dat_w = mmio_bus.dat_w;
        mmio_clint_bus.sel   = mmio_bus.sel;
        mmio_clint_bus.we    = mmio_bus.we;
        mmio_clint_bus.lock  = mmio_bus.lock;
        mmio_clint_bus.cyc   = mmio_bus.cyc && sel_clint && !mmio_ack_q;
        mmio_clint_bus.stb   = mmio_bus.stb && sel_clint && !mmio_ack_q;
    end

    always_comb begin
        mmio_bus.ack = mmio_ack_q;
        mmio_bus.stall = 1'b0;

        unique case (1'b1)
            sel_leds: begin
                mmio_bus.dat_r = mmio_gpio_bus.dat_r;
            end
            sel_uart: begin
                mmio_bus.dat_r = mmio_uart_bus.dat_r;
            end
            sel_i2c: begin
                mmio_bus.dat_r = mmio_i2c_bus.dat_r;
            end
            sel_timer: begin
                mmio_bus.dat_r = mmio_timer_bus.dat_r;
            end
            sel_spi: begin
                mmio_bus.dat_r = mmio_spi_bus.dat_r;
            end
            sel_sd: begin
                mmio_bus.dat_r = mmio_sd_bus.dat_r;
            end
            sel_clint: begin
                mmio_bus.dat_r = mmio_clint_bus.dat_r;
            end
            default: begin
                mmio_bus.dat_r = 32'b0;
            end
        endcase
    end

    gpio_mmio #(.LEDS_W(6)) u_gpio_mmio (
        .clk(clk),
        .rst_n(rst_n),
        .bus(mmio_gpio_bus),
        .leds(leds)
    );

    uart_mmio u_uart_mmio (
        .clk(clk),
        .rst_n(rst_n),
        .rxd(rxd),
        .txd(txd),
        .bus(mmio_uart_bus)
    );

    i2c_mmio u_i2c_mmio (
        .clk(clk),
        .rst_n(rst_n),
        .bus(mmio_i2c_bus),
        .sda(i2c_sda),
        .scl(i2c_scl)
    );

    logic timer_irq;
    timer_mmio u_timer_mmio (
        .clk(clk),
        .rst_n(rst_n),
        .timer_irq(timer_irq),
        .bus(mmio_timer_bus)
    );

    logic clint_timer_irq;
    logic clint_sw_irq;
    clint u_clint (
        .clk(clk),
        .rst_n(rst_n),
        .timer_irq(clint_timer_irq),
        .sw_irq(clint_sw_irq),
        .bus(mmio_clint_bus)
    );

    spi_mmio u_spi_mmio (
        .clk(clk),
        .rst_n(rst_n),
        .bus(mmio_spi_bus),
        .spi_cs_n(spi_cs_n),
        .spi_sck(spi_sck),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso)
    );

    sdhost_mmio u_sdhost_mmio (
        .clk(clk),
        .rst_n(rst_n),
        .bus(mmio_sd_bus),
        .sdclk(sdclk),
        .sdcmd(sdcmd),
        .sddat(sddat)
    );

`ifdef BENCH
    logic sd_rdreq;
    logic [39:0] sd_rdaddr;
    logic [15:0] sd_rddata;
`ifndef SIM_SD_IMAGE_WORDS
`define SIM_SD_IMAGE_WORDS 8388608
`endif
    localparam integer SIM_SD_IMAGE_ADDR_WIDTH = $clog2(`SIM_SD_IMAGE_WORDS);
    logic [15:0] sd_image [0:`SIM_SD_IMAGE_WORDS-1];

    // sd_fake's rdreq/rdaddr port models a synchronous backing RAM: rdaddr is
    // advanced while rdreq is low, then rdreq latches that word for the next
    // 16 serial data bits.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sd_rddata <= 16'b0;
        else if (sd_rdreq)
            sd_rddata <= sd_image[sd_rdaddr[SIM_SD_IMAGE_ADDR_WIDTH-1:0]];
    end

    sd_fake u_sd_fake (
        .rstn_async(rst_n),
        .sdclk(sdclk),
        .sdcmd(sdcmd),
        .sddat(sddat),
        .rdreq(sd_rdreq),
        .rdaddr(sd_rdaddr),
        .rddata(sd_rddata),
        .show_status_bits(),
        .show_sdcmd_en(),
        .show_sdcmd_cmd(),
        .show_sdcmd_arg()
    );

    initial begin
`ifndef SIM_SD_IMAGE_PATH
`define SIM_SD_IMAGE_PATH "program/build/sd_image.hex"
`endif
        $readmemh(`SIM_SD_IMAGE_PATH, sd_image);
    end
`endif

    logic ddr_owner_valid;
    logic ddr_owner_is_data;
    logic ddr_owner_cooldown;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ddr_owner_valid <= 1'b0;
            ddr_owner_is_data <= 1'b0;
            ddr_owner_cooldown <= 1'b0;
        end
        else if (ddr_owner_valid) begin
            if (ddr_owner_is_data) begin
                // A speculative PTW can withdraw CYC while its request is
                // still inside the DDR bridge.  Keep the old owner while the
                // bridge is busy so the late response cannot reach the next
                // master.
                if (!ddr_data_bus.lock &&
                    (ddr_bus.ack || (!ddr_data_bus.cyc && !ddr_bus.stall))) begin
                    ddr_owner_valid <= 1'b0;
                    ddr_owner_cooldown <= ddr_bus.ack;
                end
            end
            else if (!ddr_instr_bus.lock &&
                     (ddr_bus.ack ||
                      (!ddr_instr_bus.cyc && !ddr_bus.stall))) begin
                    ddr_owner_valid <= 1'b0;
                    ddr_owner_cooldown <= ddr_bus.ack;
            end
        end
        else if (ddr_owner_cooldown) begin
            // The DDR bridge returns ACK/data through registers.  Keep one
            // idle routing cycle after an acknowledged transfer so that its
            // response tail cannot be observed by the next owner.
            ddr_owner_cooldown <= 1'b0;
        end
        else if (ddr_data_bus.cyc) begin
            ddr_owner_valid <= 1'b1;
            ddr_owner_is_data <= 1'b1;
        end
        else if (ddr_instr_bus.cyc) begin
            ddr_owner_valid <= 1'b1;
            ddr_owner_is_data <= 1'b0;
        end
    end

    always_comb begin
        if (ddr_owner_cooldown || !ddr_owner_valid) begin
            ddr_bus.adr = 32'b0;
            ddr_bus.dat_w = 32'b0;
            ddr_bus.sel = 4'b0;
            ddr_bus.we = 1'b0;
            ddr_bus.lock = 1'b0;
            ddr_bus.cyc = 1'b0;
            ddr_bus.stb = 1'b0;
            ddr_data_bus.dat_r = 32'b0;
            ddr_data_bus.ack = 1'b0;
            ddr_data_bus.stall = ddr_data_bus.cyc;
            ddr_instr_bus.dat_r = 32'b0;
            ddr_instr_bus.ack = 1'b0;
            ddr_instr_bus.stall = ddr_instr_bus.cyc;
        end
        else if (ddr_owner_is_data) begin
            ddr_bus.adr = ddr_data_bus.adr;
            ddr_bus.dat_w = ddr_data_bus.dat_w;
            ddr_bus.sel = ddr_data_bus.sel;
            ddr_bus.we = ddr_data_bus.we;
            ddr_bus.lock = ddr_data_bus.lock;
            ddr_bus.cyc = ddr_data_bus.cyc;
            ddr_bus.stb = ddr_data_bus.stb;
            ddr_data_bus.dat_r = ddr_bus.dat_r;
            ddr_data_bus.ack = ddr_bus.ack;
            ddr_data_bus.stall = ddr_bus.stall;
            ddr_instr_bus.dat_r = 32'b0;
            ddr_instr_bus.ack = 1'b0;
            ddr_instr_bus.stall = ddr_instr_bus.cyc;
        end
        else begin
            ddr_bus.adr = ddr_instr_bus.adr;
            ddr_bus.dat_w = ddr_instr_bus.dat_w;
            ddr_bus.sel = ddr_instr_bus.sel;
            ddr_bus.we = ddr_instr_bus.we;
            ddr_bus.lock = ddr_instr_bus.lock;
            ddr_bus.cyc = ddr_instr_bus.cyc;
            ddr_bus.stb = ddr_instr_bus.stb;
            ddr_instr_bus.dat_r = ddr_bus.dat_r;
            ddr_instr_bus.ack = ddr_bus.ack;
            ddr_instr_bus.stall = ddr_bus.stall;
            ddr_data_bus.dat_r = 32'b0;
            ddr_data_bus.ack = 1'b0;
            ddr_data_bus.stall = ddr_data_bus.cyc;
        end
    end

    ddr3_wb_bridge u_ddr3_wb_bridge (
        .clk(clk),
        .app_clk(ddr_app_clk),
        .rst_n(rst_n),
        .bus(ddr_bus),
        .app_addr(ddr_app_addr),
        .app_cmd_en(ddr_app_cmd_en),
        .app_cmd(ddr_app_cmd),
        .app_cmd_rdy(ddr_app_cmd_rdy),
        .app_wren(ddr_app_wren),
        .app_data_end(ddr_app_data_end),
        .app_data(ddr_app_data),
        .app_data_rdy(ddr_app_data_rdy),
        .app_rdata_valid(ddr_app_rdata_valid),
        .app_rdata_end(ddr_app_rdata_end),
        .app_rdata(ddr_app_rdata),
        .init_calib_complete(ddr_init_calib_complete),
        .app_burst_number(ddr_app_burst_number),
        .app_idle(ddr_app_idle)
    );

`ifdef BENCH
    always_ff @(posedge clk) begin
        if (mmio_uart_bus.cyc && mmio_uart_bus.stb && mmio_uart_bus.we &&
            (align_word(mmio_uart_bus.adr) == IO_UART_DAT_ADDR)) begin
            $write("%c", mmio_uart_bus.dat_w[7:0]);
        end
    end
`endif

endmodule
