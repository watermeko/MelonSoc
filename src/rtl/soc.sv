`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"
`include "core/cpu.sv"
`include "core/mem.sv"
`include "include/peripherals.sv"
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

        // DDR3 APP 接口（对接 Gowin DDR3_Memory_Interface_Top）
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
        output logic [5:0]   ddr_app_burst_number
    );
    import soc_pkg::*;

    // 指令，数据，外设总线
    imem_if       instr_bus();
    simple_bus_if cpu_data_bus();
    simple_bus_if ram_bus();
    simple_bus_if mmio_bus();

    simple_bus_if mmio_gpio_bus();
    simple_bus_if mmio_uart_bus();
    simple_bus_if mmio_i2c_bus();
    simple_bus_if mmio_timer_bus();
    simple_bus_if mmio_spi_bus();
    simple_bus_if mmio_ddr_bus();
    simple_bus_if mmio_clint_bus();

    cpu u_cpu (
            .clk(clk),
            .rst_n(rst_n),
            .ext_irq(timer_irq),
            .sw_irq(clint_sw_irq),
            .timer_irq(clint_timer_irq),
            .instr(instr_bus),
            .data(cpu_data_bus)
        );

    mem u_mem (
            .clk(clk),
            .instr(instr_bus),
            .data(ram_bus)
        );

    logic data_req_any;
    logic data_is_mmio;
    logic data_is_mmio_q;

    always_comb begin
        data_req_any = cpu_data_bus.ren || cpu_data_bus.wen;
        data_is_mmio = is_mmio_region(cpu_data_bus.addr);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_is_mmio_q <= 1'b0;
        end
        else if (data_req_any) begin
            data_is_mmio_q <= data_is_mmio;
        end
    end

    // 内存&外设映射
    always_comb begin
        ram_bus.addr  = cpu_data_bus.addr;
        ram_bus.ren   = cpu_data_bus.ren & ~data_is_mmio;
        ram_bus.wen   = cpu_data_bus.wen & ~data_is_mmio;
        ram_bus.wdata = cpu_data_bus.wdata;
        ram_bus.wstrb = cpu_data_bus.wstrb & {4{~data_is_mmio}};

        mmio_bus.addr  = cpu_data_bus.addr;
        mmio_bus.ren   = cpu_data_bus.ren & data_is_mmio;
        mmio_bus.wen   = cpu_data_bus.wen & data_is_mmio;
        mmio_bus.wdata = cpu_data_bus.wdata;
        mmio_bus.wstrb = cpu_data_bus.wstrb & {4{data_is_mmio}};

        cpu_data_bus.rdata = data_is_mmio_q ? mmio_bus.rdata : ram_bus.rdata;
    end

    // MMIO解码
    logic sel_leds;
    logic sel_uart;
    logic sel_i2c;
    logic sel_timer;
    logic sel_spi;
    logic sel_ddr;
    logic sel_clint;

    always_comb begin
        sel_leds = (align_word(mmio_bus.addr) == IO_LEDS_ADDR);
        sel_uart = (align_word(mmio_bus.addr) == IO_UART_DAT_ADDR) ||
                 (align_word(mmio_bus.addr) == IO_UART_CTRL_ADDR);
        sel_i2c  = (align_word(mmio_bus.addr) == IO_I2C_TXRX_ADDR) ||
                 (align_word(mmio_bus.addr) == IO_I2C_CMD_ADDR) ||
                 (align_word(mmio_bus.addr) == IO_I2C_STATUS_ADDR) ||
                 (align_word(mmio_bus.addr) == IO_I2C_DIV_ADDR);
        sel_timer = (align_word(mmio_bus.addr) == IO_TIMER_CTRL_ADDR) ||
                  (align_word(mmio_bus.addr) == IO_TIMER_PRESC_ADDR) ||
                  (align_word(mmio_bus.addr) == IO_TIMER_COUNT_ADDR) ||
                  (align_word(mmio_bus.addr) == IO_TIMER_CMP_ADDR) ||
                  (align_word(mmio_bus.addr) == IO_TIMER_PERIOD_ADDR) ||
                  (align_word(mmio_bus.addr) == IO_TIMER_STATUS_ADDR);
        sel_spi = (align_word(mmio_bus.addr) == IO_SPI_TXRX_ADDR) ||
                (align_word(mmio_bus.addr) == IO_SPI_CTRL_ADDR) ||
                (align_word(mmio_bus.addr) == IO_SPI_STATUS_ADDR) ||
                (align_word(mmio_bus.addr) == IO_SPI_DIV_ADDR);

        sel_ddr = (align_word(mmio_bus.addr) == IO_DDR_CTRL_ADDR) ||
                (align_word(mmio_bus.addr) == IO_DDR_STATUS_ADDR) ||
                (align_word(mmio_bus.addr) == IO_DDR_ADDR_ADDR) ||
                (align_word(mmio_bus.addr) == IO_DDR_BURST_ADDR) ||
                (align_word(mmio_bus.addr) == IO_DDR_WDATA0_ADDR) ||
                (align_word(mmio_bus.addr) == IO_DDR_WDATA1_ADDR) ||
                (align_word(mmio_bus.addr) == IO_DDR_WDATA2_ADDR) ||
                (align_word(mmio_bus.addr) == IO_DDR_WDATA3_ADDR) ||
                (align_word(mmio_bus.addr) == IO_DDR_RDATA0_ADDR) ||
                (align_word(mmio_bus.addr) == IO_DDR_RDATA1_ADDR) ||
                (align_word(mmio_bus.addr) == IO_DDR_RDATA2_ADDR) ||
                (align_word(mmio_bus.addr) == IO_DDR_RDATA3_ADDR);

        sel_clint = (align_word(mmio_bus.addr) == IO_CLINT_MSIP_ADDR) ||
                  (align_word(mmio_bus.addr) == IO_CLINT_MTIMECMP_ADDR) ||
                  (align_word(mmio_bus.addr) == (IO_CLINT_MTIMECMP_ADDR + 4)) ||
                  (align_word(mmio_bus.addr) == IO_CLINT_MTIME_ADDR) ||
                  (align_word(mmio_bus.addr) == (IO_CLINT_MTIME_ADDR + 4));

        mmio_gpio_bus.addr  = mmio_bus.addr;
        mmio_gpio_bus.ren   = mmio_bus.ren & sel_leds;
        mmio_gpio_bus.wen   = mmio_bus.wen & sel_leds;
        mmio_gpio_bus.wdata = mmio_bus.wdata;
        mmio_gpio_bus.wstrb = mmio_bus.wstrb;

        mmio_uart_bus.addr  = mmio_bus.addr;
        mmio_uart_bus.ren   = mmio_bus.ren & sel_uart;
        mmio_uart_bus.wen   = mmio_bus.wen & sel_uart;
        mmio_uart_bus.wdata = mmio_bus.wdata;
        mmio_uart_bus.wstrb = mmio_bus.wstrb;

        mmio_i2c_bus.addr  = mmio_bus.addr;
        mmio_i2c_bus.ren   = mmio_bus.ren & sel_i2c;
        mmio_i2c_bus.wen   = mmio_bus.wen & sel_i2c;
        mmio_i2c_bus.wdata = mmio_bus.wdata;
        mmio_i2c_bus.wstrb = mmio_bus.wstrb;

        mmio_timer_bus.addr  = mmio_bus.addr;
        mmio_timer_bus.ren   = mmio_bus.ren & sel_timer;
        mmio_timer_bus.wen   = mmio_bus.wen & sel_timer;
        mmio_timer_bus.wdata = mmio_bus.wdata;
        mmio_timer_bus.wstrb = mmio_bus.wstrb;

        mmio_spi_bus.addr  = mmio_bus.addr;
        mmio_spi_bus.ren   = mmio_bus.ren & sel_spi;
        mmio_spi_bus.wen   = mmio_bus.wen & sel_spi;
        mmio_spi_bus.wdata = mmio_bus.wdata;
        mmio_spi_bus.wstrb = mmio_bus.wstrb;

        mmio_ddr_bus.addr  = mmio_bus.addr;
        mmio_ddr_bus.ren   = mmio_bus.ren & sel_ddr;
        mmio_ddr_bus.wen   = mmio_bus.wen & sel_ddr;
        mmio_ddr_bus.wdata = mmio_bus.wdata;
        mmio_ddr_bus.wstrb = mmio_bus.wstrb;

        mmio_clint_bus.addr  = mmio_bus.addr;
        mmio_clint_bus.ren   = mmio_bus.ren & sel_clint;
        mmio_clint_bus.wen   = mmio_bus.wen & sel_clint;
        mmio_clint_bus.wdata = mmio_bus.wdata;
        mmio_clint_bus.wstrb = mmio_bus.wstrb;
    end

    gpio_mmio #(
                  .LEDS_W(6)
              ) u_gpio_mmio (
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

    ddr3_app_mmio u_ddr3_app_mmio (
                     .clk(clk),
                     .app_clk(ddr_app_clk),
                     .rst_n(rst_n),
                     .bus(mmio_ddr_bus),

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
                     .app_burst_number(ddr_app_burst_number)
                 );

    logic [31:0] mmio_rdata_comb;
    logic [31:0] mmio_rdata_q;

    always_comb begin
        unique case (1'b1)
                   sel_leds:
                       mmio_rdata_comb = mmio_gpio_bus.rdata;
                   sel_uart:
                       mmio_rdata_comb = mmio_uart_bus.rdata;
                   sel_i2c:
                       mmio_rdata_comb = mmio_i2c_bus.rdata;
                   sel_timer:
                       mmio_rdata_comb = mmio_timer_bus.rdata;
                   sel_spi:
                       mmio_rdata_comb = mmio_spi_bus.rdata;
                   sel_ddr:
                       mmio_rdata_comb = mmio_ddr_bus.rdata;
                   sel_clint:
                       mmio_rdata_comb = mmio_clint_bus.rdata;
                   default:
                       mmio_rdata_comb = 32'b0;
               endcase
           end

           always_ff @(posedge clk or negedge rst_n) begin
               if (!rst_n) begin
                   mmio_rdata_q <= 32'b0;
               end
               else if (mmio_bus.ren) begin
                   mmio_rdata_q <= mmio_rdata_comb;
               end
           end

           always_comb begin
               mmio_bus.rdata = mmio_rdata_q;
           end

`ifdef BENCH
           // Convenient UART output tap for simulation.
           always_ff @(posedge clk) begin
               if (mmio_bus.wen && (align_word(mmio_bus.addr) == IO_UART_DAT_ADDR)) begin
                   $write("%c", mmio_bus.wdata[7:0]);
               end
           end
`endif

endmodule
