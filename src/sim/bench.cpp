#include "VSOC.h"
#include "verilated.h"

#include <cerrno>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <fstream>
#include <iterator>
#include <poll.h>
#include <string>
#include <unordered_map>
#include <vector>

#include <fcntl.h>
#include <unistd.h>

namespace {

static uint64_t parse_u64(const char* s, uint64_t fallback) {
  if (!s || !*s) return fallback;
  char* end = nullptr;
  errno = 0;
  unsigned long long v = std::strtoull(s, &end, 0);
  if (errno != 0 || end == s || (end && *end != '\0')) return fallback;
  return static_cast<uint64_t>(v);
}

static uint32_t parse_u32(const char* s, uint32_t fallback) {
  uint64_t v = parse_u64(s, fallback);
  if (v > 0xFFFF'FFFFull) return fallback;
  return static_cast<uint32_t>(v);
}

static void set_stdin_nonblocking() {
  int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
  if (flags < 0) return;
  (void)fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
}

static std::string read_file_all(const std::string& path) {
  std::ifstream ifs(path, std::ios::binary);
  if (!ifs) return {};
  return std::string((std::istreambuf_iterator<char>(ifs)), std::istreambuf_iterator<char>());
}

struct UartRxStim {
  uint32_t baud_ticks = 234;  // default for 27MHz/115200 ~= 234.375
  uint32_t cycles_left = 0;
  int line = 1;  // idle high
  std::deque<int> bits;

  void set_params(uint32_t clk_hz, uint32_t baud) {
    if (baud == 0) baud = 115200;
    // Match uart_rx_simple.sv rounding: ((CLK_FREQ + (UART_BAUD/2)) / UART_BAUD)
    uint32_t ticks = (clk_hz + (baud / 2)) / baud;
    if (ticks == 0) ticks = 1;
    baud_ticks = ticks;
  }

  void enqueue_byte(uint8_t b) {
    bits.push_back(0);  // start
    for (int i = 0; i < 8; ++i) bits.push_back((b >> i) & 1);
    bits.push_back(1);  // stop
  }

  void enqueue_bytes(const std::string& s) {
    for (unsigned char ch : s) enqueue_byte(static_cast<uint8_t>(ch));
  }

  void tick() {
    if (cycles_left > 0) {
      cycles_left--;
      return;
    }

    if (!bits.empty()) {
      line = bits.front();
      bits.pop_front();
      cycles_left = (baud_ticks > 0) ? (baud_ticks - 1) : 0;
      return;
    }

    line = 1;
    cycles_left = 0;
  }
};

struct SimArgs {
  bool interactive = true;
  uint64_t max_cycles = 0;
  bool max_cycles_user = false;
  uint32_t clk_hz = 27'000'000;
  uint32_t uart_baud = 115'200;
  std::vector<std::string> sim_args;
};

struct DdrAppModel {
  std::unordered_map<uint32_t, std::array<uint32_t, 4>> mem;
  bool read_pending = false;
  uint32_t read_addr = 0;

  static uint32_t line_addr(uint32_t app_addr) {
    return app_addr & ~0x7u;
  }

  void drive(VSOC& dut) {
    dut.ddr_app_cmd_rdy = 1;
    dut.ddr_app_data_rdy = 1;
    dut.ddr_init_calib_complete = 1;
    dut.ddr_app_rdata_valid = read_pending ? 1 : 0;
    dut.ddr_app_rdata_end = read_pending ? 1 : 0;

    auto& line = mem[line_addr(read_addr)];
    dut.ddr_app_rdata[0] = read_pending ? line[0] : 0;
    dut.ddr_app_rdata[1] = read_pending ? line[1] : 0;
    dut.ddr_app_rdata[2] = read_pending ? line[2] : 0;
    dut.ddr_app_rdata[3] = read_pending ? line[3] : 0;
  }

  void sample(VSOC& dut) {
    read_pending = false;
    if (!dut.ddr_app_cmd_en) return;

    uint32_t addr = line_addr(dut.ddr_app_addr);
    if (dut.ddr_app_cmd == 0 && dut.ddr_app_wren) {
      auto& line = mem[addr];
      line[0] = dut.ddr_app_data[0];
      line[1] = dut.ddr_app_data[1];
      line[2] = dut.ddr_app_data[2];
      line[3] = dut.ddr_app_data[3];
    } else if (dut.ddr_app_cmd == 1) {
      read_pending = true;
      read_addr = addr;
    }
  }
};

static void print_help(const char* argv0) {
  std::fprintf(
      stderr,
      "Usage: %s [options]\n"
      "\n"
      "Options:\n"
      "  --interactive           Poll stdin and inject as UART RX (default)\n"
      "  --max-cycles <N>        Stop after N cycles (0 = run forever)\n"
      "  --clk-hz <N>            SOC clk frequency (default: 27000000)\n"
      "  --uart-baud <N>         UART baud (default: 115200)\n"
      "  --sim-arg <cmd>         Shell command to inject via UART at startup.\n"
      "                          Repeatable; each is sent with a 1M-cycle gap.\n"
      "  --help                  Show this help\n",
      argv0);
}

static SimArgs parse_args(int argc, char** argv) {
  SimArgs a;
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--help" || arg == "-h") {
      print_help(argv[0]);
      std::exit(0);
    } else if (arg == "--interactive") {
      a.interactive = true;
    } else if (arg == "--max-cycles" && i + 1 < argc) {
      a.max_cycles = parse_u64(argv[++i], a.max_cycles);
      a.max_cycles_user = true;
    } else if (arg == "--clk-hz" && i + 1 < argc) {
      a.clk_hz = parse_u32(argv[++i], a.clk_hz);
    } else if (arg == "--uart-baud" && i + 1 < argc) {
      a.uart_baud = parse_u32(argv[++i], a.uart_baud);
    } else if (arg == "--sim-arg" && i + 1 < argc) {
      a.sim_args.push_back(argv[++i]);
    } else {
      std::fprintf(stderr, "Unknown arg: %s\n", arg.c_str());
      print_help(argv[0]);
      std::exit(2);
    }
  }
  return a;
}

static bool poll_stdin_and_enqueue(UartRxStim& uart, bool& eof_seen) {
  if (eof_seen) return false;

  pollfd pfd;
  pfd.fd = STDIN_FILENO;
  pfd.events = POLLIN;
  pfd.revents = 0;
  int r = ::poll(&pfd, 1, 0);
  if (r <= 0) return false;
  if ((pfd.revents & POLLIN) == 0) return false;

  bool enqueued_any = false;
  for (;;) {
    uint8_t buf[256];
    ssize_t n = ::read(STDIN_FILENO, buf, sizeof(buf));
    if (n > 0) {
      enqueued_any = true;
      for (ssize_t i = 0; i < n; ++i) uart.enqueue_byte(buf[i]);
      continue;
    }
    if (n == 0) {
      eof_seen = true;
      break;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) break;
    eof_seen = true;
    break;
  }
  return enqueued_any;
}

}

static void eval_dut(VSOC& dut, DdrAppModel& ddr, vluint64_t& time) {
  ddr.drive(dut);
  dut.eval();
  time++;
}

static void tick_app(VSOC& dut, DdrAppModel& ddr, vluint64_t& time) {
  dut.ddr_app_clk = 0;
  eval_dut(dut, ddr, time);

  dut.ddr_app_clk = 1;
  eval_dut(dut, ddr, time);
  ddr.sample(dut);
}

static void tick(VSOC& dut, DdrAppModel& ddr, vluint64_t& time) {
  dut.spi_miso = 1;

  for (int i = 0; i < 4; ++i) {
    dut.clk = (i >= 2) ? 1 : 0;
    tick_app(dut, ddr, time);
  }

  dut.clk = 0;
  dut.ddr_app_clk = 0;
  eval_dut(dut, ddr, time);
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  SimArgs args = parse_args(argc, argv);
  set_stdin_nonblocking();

  VSOC dut;
  DdrAppModel ddr;
  vluint64_t time = 0;

  UartRxStim uart;
  uart.set_params(args.clk_hz, args.uart_baud);

  if (!args.max_cycles_user && !::isatty(STDIN_FILENO)) {
    args.max_cycles = 80'000'000;
  }

  dut.rxd = 1;
  dut.i2c_sda= 1;
  dut.spi_miso = 1;
  dut.rst_n = 0;
  for (int i = 0; i < 10; ++i) tick(dut, ddr, time);
  dut.rst_n = 1;

  bool eof_seen = false;
  uint32_t poll_div = 0;
  size_t sim_arg_idx = 0;
  bool sim_args_all_sent = args.sim_args.empty();

  uint64_t i = 0;
  while (!Verilated::gotFinish()) {
    if (args.max_cycles != 0 && i >= args.max_cycles) break;

    // Inject --sim-arg commands at intervals after boot.
    // First command at 2M cycles, subsequent every 1M.
    if (!sim_args_all_sent) {
      uint64_t trigger_cycle = 2'000'000 + sim_arg_idx * 1'000'000;
      if (i == trigger_cycle) {
        uart.enqueue_bytes(args.sim_args[sim_arg_idx]);
        uart.enqueue_byte('\n');
        sim_arg_idx++;
        if (sim_arg_idx >= args.sim_args.size())
          sim_args_all_sent = true;
      }
    }

    if (args.interactive) {
      // Throttle stdin polling to reduce overhead.
      if (poll_div == 0) {
        poll_stdin_and_enqueue(uart, eof_seen);
        poll_div = 1024;
      } else {
        poll_div--;
      }
    }

    uart.tick();
    dut.rxd = uart.line;

    tick(dut, ddr, time);
    ++i;
  }

  dut.final();
  return 0;
}
