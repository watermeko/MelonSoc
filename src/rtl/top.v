`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"
module top(
  input  clk,        // system clock
  input  rst_n,      // reset button
  output [5:0] leds, // system LEDs
  input  rxd,        // UART receive
  output txd,        // UART transmit
  inout  i2c_scl,    // I2C clock (open-drain)
  inout  i2c_sda,    // I2C data  (open-drain)

  output sd_cs_n,    // SD card SPI CS (active-low)
  output sd_sck,     // SD card SPI clock
  output sd_mosi,    // SD card SPI MOSI
  input  sd_miso     // SD card SPI MISO
);

wire i2c_scl_drive_low;
wire i2c_sda_drive_low;

// Open-drain: drive low or release (needs pull-up resistors).
assign i2c_scl = i2c_scl_drive_low ? 1'b0 : 1'bz;
assign i2c_sda = i2c_sda_drive_low ? 1'b0 : 1'bz;
wire i2c_sda_in = i2c_sda;

SOC u_soc(
    .clk        (clk       ),
    .rst_n      (rst_n     ),
    .leds       (leds      ),
    .rxd        (rxd       ),
    .txd        (txd       ),
    .i2c_scl_drive_low(i2c_scl_drive_low),
    .i2c_sda_drive_low(i2c_sda_drive_low),
    .i2c_sda_in(i2c_sda_in),
    .spi_cs_n(sd_cs_n),
    .spi_sck(sd_sck),
    .spi_mosi(sd_mosi),
    .spi_miso(sd_miso)
);
endmodule
