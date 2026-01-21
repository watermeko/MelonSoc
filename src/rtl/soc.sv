`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"
`include "core/cpu.sv"
`include "core/mem.sv"
`include "include/peripherals.sv"
module SOC (
        input  logic clk,
        input  logic rst_n,
        output logic [5:0] leds,
        input  logic rxd,
        output logic txd,

        inout  tri   i2c_scl,
        inout  tri   i2c_sda,

        output logic spi_cs_n,
        output logic spi_sck,
        output logic spi_mosi,
        input  logic spi_miso
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

    cpu u_cpu (
            .clk(clk),
            .rst_n(rst_n),
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

    timer_mmio u_timer_mmio (
                   .clk(clk),
                   .rst_n(rst_n),
                   .bus(mmio_timer_bus)
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
