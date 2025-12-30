#include "VSOC.h"
#include "verilated.h"

static void tick(VSOC& dut, vluint64_t& time) {
  dut.clk = 0;
  dut.eval();
  time++;

  dut.i2c_sda_in = dut.i2c_sda_drive_low ? 0 : 1;
  dut.spi_miso = 1;

  dut.clk = 1;
  dut.eval();
  time++;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  VSOC dut;
  vluint64_t time = 0;

  dut.rxd = 1;
  dut.i2c_sda_in = 1;
  dut.spi_miso = 1;
  dut.rst_n = 0;
  for (int i = 0; i < 10; ++i) tick(dut, time);
  dut.rst_n = 1;

  const int max_cycles = 20'000'000;
  for (int i = 0; i < max_cycles && !Verilated::gotFinish(); ++i) {
    tick(dut, time);
  }

  dut.final();
  return 0;
}
