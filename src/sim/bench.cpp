#include "VSOC.h"
#include "verilated.h"

static void tick(VSOC& dut, vluint64_t& time) {
  // No DDR model in this bench; keep DDR inputs deasserted.
  dut.ddr_app_cmd_rdy = 0;
  dut.ddr_app_data_rdy = 0;
  dut.ddr_app_rdata_valid = 0;
  dut.ddr_app_rdata_end = 0;
  dut.ddr_init_calib_complete = 0;
  dut.ddr_app_rdata[0] = 0;
  dut.ddr_app_rdata[1] = 0;
  dut.ddr_app_rdata[2] = 0;
  dut.ddr_app_rdata[3] = 0;

  dut.clk = 0;
  dut.ddr_app_clk = 0;
  dut.eval();
  time++;

  dut.spi_miso = 1;

  dut.clk = 1;
  dut.ddr_app_clk = 1;
  dut.eval();
  time++;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  VSOC dut;
  vluint64_t time = 0;

  dut.rxd = 1;
  dut.i2c_sda= 1;
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
