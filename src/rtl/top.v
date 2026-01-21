`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"
module top(
        input  clk,
        input  rst_n,
        output [5:0] leds,
        input  rxd,
        output txd,
        inout  i2c_scl,
        inout  i2c_sda,

        output sd_cs_n,
        output sd_sck,
        output sd_mosi,
        input  sd_miso
    );

    wire i2c_scl_drive_low;
    wire i2c_sda_drive_low;


    SOC u_soc(
            .clk        (clk       ),
            .rst_n      (rst_n     ),
            .leds       (leds      ),
            .rxd        (rxd       ),
            .txd        (txd       ),
            .i2c_scl    (i2c_scl   ),
            .i2c_sda    (i2c_sda   ),
            .spi_cs_n(sd_cs_n),
            .spi_sck(sd_sck),
            .spi_mosi(sd_mosi),
            .spi_miso(sd_miso)
        );
endmodule
