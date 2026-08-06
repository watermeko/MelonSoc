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

struct UartTxMonitor {
  enum State { IDLE, START, DATA, STOP } state = IDLE;
  uint32_t baud_ticks = 234;
  uint32_t ticks_left = 0;
  uint8_t byte = 0;
  int bit_index = 0;

  void set_params(uint32_t clk_hz, uint32_t baud) {
    if (baud == 0) baud = 115200;
    uint32_t ticks = clk_hz / baud;
    if (ticks == 0) ticks = 1;
    baud_ticks = ticks;
  }

  int tick(int line) {
    switch (state) {
      case IDLE:
        if (line == 0) {
          state = START;
          ticks_left = baud_ticks / 2;
        }
        break;
      case START:
        if (ticks_left > 0) {
          --ticks_left;
        } else if (line == 0) {
          state = DATA;
          bit_index = 0;
          byte = 0;
          ticks_left = baud_ticks;
        } else {
          state = IDLE;
        }
        break;
      case DATA:
        if (ticks_left > 0) {
          --ticks_left;
        } else {
          byte |= static_cast<uint8_t>((line != 0) << bit_index);
          if (bit_index == 7)
            state = STOP;
          else
            ++bit_index;
          ticks_left = baud_ticks;
        }
        break;
      case STOP:
        if (ticks_left > 0) {
          --ticks_left;
        } else {
          state = IDLE;
          return line != 0 ? static_cast<int>(byte) : -1;
        }
        break;
    }
    return -1;
  }
};

struct XmodemSender {
  enum State { WAIT_C, WAIT_ACK, WAIT_EOT_ACK, DONE, FAILED } state = WAIT_C;
  std::string image;
  uint32_t offset = 0;
  uint8_t block_no = 1;
  uint32_t retries = 0;
  int corrupt_block = -1;
  bool corrupted_once = false;

  static uint16_t crc16_ccitt(const uint8_t* data, size_t size) {
    uint32_t crc = 0;
    for (size_t i = 0; i < size; ++i) {
      crc ^= static_cast<uint32_t>(data[i]) << 8;
      for (int bit = 0; bit < 8; ++bit) {
        if (crc & 0x8000u)
          crc = (crc << 1) ^ 0x1021u;
        else
          crc <<= 1;
        crc &= 0xffffu;
      }
    }
    return static_cast<uint16_t>(crc);
  }

  void enqueue_frame(UartRxStim& uart) {
    std::array<uint8_t, 128> data{};
    data.fill(0x1A);
    size_t remaining = image.size() - offset;
    size_t count = remaining < data.size() ? remaining : data.size();
    for (size_t i = 0; i < count; ++i)
      data[i] = static_cast<uint8_t>(image[offset + i]);

    uart.enqueue_byte(0x01);
    uart.enqueue_byte(block_no);
    uart.enqueue_byte(static_cast<uint8_t>(0xFFu - block_no));
    for (uint8_t byte : data)
      uart.enqueue_byte(byte);

    uint16_t crc = crc16_ccitt(data.data(), data.size());
    if (static_cast<int>(block_no) == corrupt_block && !corrupted_once) {
      crc ^= 0x0001u;
      corrupted_once = true;
    }
    uart.enqueue_byte(static_cast<uint8_t>(crc >> 8));
    uart.enqueue_byte(static_cast<uint8_t>(crc));
    state = WAIT_ACK;
  }

  void on_tx_byte(int byte, UartRxStim& uart) {
    if (byte < 0 || state == DONE || state == FAILED)
      return;

    if (state == WAIT_C && byte == 'C') {
      if (image.empty()) {
        state = FAILED;
        return;
      }
      enqueue_frame(uart);
      return;
    }

    if (state == WAIT_ACK) {
      if (byte == 0x06) {
        size_t remaining = image.size() - offset;
        offset += remaining < 128 ? remaining : 128;
        retries = 0;
        if (offset >= image.size()) {
          uart.enqueue_byte(0x04);
          state = WAIT_EOT_ACK;
        } else {
          ++block_no;
          enqueue_frame(uart);
        }
      } else if (byte == 0x15) {
        if (++retries >= 16)
          state = FAILED;
        else
          enqueue_frame(uart);
      } else if (byte == 0x18) {
        state = FAILED;
      }
      return;
    }

    if (state == WAIT_EOT_ACK) {
      if (byte == 0x06)
        state = DONE;
      else if (byte == 0x18)
        state = FAILED;
    }
  }
};

struct SimArgs {
  bool interactive = true;
  uint64_t max_cycles = 0;
  bool max_cycles_user = false;
  uint32_t clk_hz = 27'000'000;
  uint32_t uart_baud = 115'200;
  std::vector<std::string> sim_args;
  std::string xmodem_image;
  std::string ddr_image;
  std::string expect;
  int xmodem_corrupt_block = -1;
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
      "  --xmodem-image <file>   Auto-run uartload and send BOOT.BIN.\n"
      "  --ddr-image <file>      Preload a flat image at DDR 0x80000000.\n"
      "  --expect <text>         Exit successfully after UART prints text.\n"
      "  --xmodem-corrupt-block <N>  Corrupt block N once for retry testing.\n"
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
    } else if (arg == "--xmodem-image" && i + 1 < argc) {
      a.xmodem_image = argv[++i];
    } else if (arg == "--ddr-image" && i + 1 < argc) {
      a.ddr_image = argv[++i];
    } else if (arg == "--expect" && i + 1 < argc) {
      a.expect = argv[++i];
    } else if (arg == "--xmodem-corrupt-block" && i + 1 < argc) {
      a.xmodem_corrupt_block = static_cast<int>(parse_u32(argv[++i], 0));
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
  UartTxMonitor tx_monitor;
  tx_monitor.set_params(args.clk_hz, args.uart_baud);

  XmodemSender xmodem;
  if (!args.xmodem_image.empty()) {
    xmodem.image = read_file_all(args.xmodem_image);
    xmodem.corrupt_block = args.xmodem_corrupt_block;
    if (xmodem.image.empty()) {
      std::fprintf(stderr, "Cannot read XMODEM image: %s\n",
                   args.xmodem_image.c_str());
      return 2;
    }
  }

  if (!args.ddr_image.empty()) {
    std::string image = read_file_all(args.ddr_image);
    if (image.empty()) {
      std::fprintf(stderr, "Cannot read DDR image: %s\n",
                   args.ddr_image.c_str());
      return 2;
    }
    for (size_t offset = 0; offset < image.size(); ++offset) {
      uint32_t app_addr = static_cast<uint32_t>(offset >> 1);
      auto& line = ddr.mem[DdrAppModel::line_addr(app_addr)];
      size_t byte_in_line = offset & 0xfu;
      size_t word = byte_in_line >> 2;
      size_t shift = (byte_in_line & 3u) * 8u;
      line[word] = (line[word] & ~(0xffu << shift)) |
                   (static_cast<uint32_t>(image[offset]) << shift);
    }
    std::fprintf(stderr, "[DDR] preloaded %zu bytes at 0x80000000\n",
                 image.size());
  }

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
  std::vector<std::string> sim_args = args.sim_args;
  if (!args.xmodem_image.empty() && sim_args.empty())
    sim_args.push_back("uartload");
  bool sim_args_all_sent = sim_args.empty();
  std::string uart_output;
  bool test_failed = false;
  bool expected_seen = false;
  size_t passed_tests = 0;
  size_t prompt_count = 0;
  uint64_t next_progress_cycle = 25'000'000;

  uint64_t i = 0;
  while (!Verilated::gotFinish()) {
    if (args.max_cycles != 0 && i >= args.max_cycles) break;
    if (i == next_progress_cycle) {
      std::fprintf(stderr, "[SIM] progress: %llu cycles\n",
                   static_cast<unsigned long long>(i));
      next_progress_cycle += 25'000'000;
    }

    // Inject --sim-arg commands at intervals after boot.
    // First command at 2M cycles, subsequent every 1M.
    if (!sim_args_all_sent) {
      uint64_t trigger_cycle = 2'000'000 + sim_arg_idx * 1'000'000;
      if (i == trigger_cycle) {
        uart.enqueue_bytes(sim_args[sim_arg_idx]);
        uart.enqueue_byte('\n');
        sim_arg_idx++;
        if (sim_arg_idx >= sim_args.size())
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
    int tx_byte = tx_monitor.tick(dut.txd);
    xmodem.on_tx_byte(tx_byte, uart);
    if (tx_byte >= 0 && (!sim_args.empty() || !args.expect.empty())) {
      uart_output.push_back(static_cast<char>(tx_byte));
      if (!args.expect.empty() &&
          uart_output.find(args.expect) != std::string::npos) {
        expected_seen = true;
        break;
      }
      if (uart_output.find("FAILED") != std::string::npos) {
        test_failed = true;
        break;
      }
      size_t pos = 0;
      size_t count = 0;
      while ((pos = uart_output.find("PASSED", pos)) != std::string::npos) {
        ++count;
        pos += 6;
      }
      passed_tests = count;
      pos = 0;
      count = 0;
      while ((pos = uart_output.find("> ", pos)) != std::string::npos) {
        ++count;
        pos += 2;
      }
      prompt_count = count;
      if (sim_args_all_sent && prompt_count >= (sim_args.size() + 1))
        break;
    }
    ++i;
  }

  if (!args.xmodem_image.empty()) {
    if (xmodem.state == XmodemSender::DONE) {
      std::fprintf(stderr, "[XMODEM] transfer complete\n");
    } else if (xmodem.state == XmodemSender::FAILED) {
      std::fprintf(stderr, "[XMODEM] transfer failed\n");
      dut.final();
      return 1;
    } else {
      std::fprintf(stderr, "[XMODEM] transfer did not finish\n");
      dut.final();
      return 1;
    }
  }

  if (!args.expect.empty()) {
    if (!expected_seen) {
      std::fprintf(stderr, "[SIM] expected UART text not seen: %s\n",
                   args.expect.c_str());
      dut.final();
      return 1;
    }
    std::fprintf(stderr, "[SIM] observed expected UART text: %s\n",
                 args.expect.c_str());
  } else if (!sim_args.empty()) {
    if (test_failed) {
      std::fprintf(stderr, "[SIM] test reported failure\n");
      dut.final();
      return 1;
    }
    if ((passed_tests < sim_args.size()) ||
        (prompt_count < (sim_args.size() + 1))) {
      std::fprintf(stderr,
                   "[SIM] tests did not complete: %zu pass markers, %zu prompts, %zu commands\n",
                   passed_tests, prompt_count, sim_args.size());
      dut.final();
      return 1;
    }
  }

  dut.final();
  return 0;
}
