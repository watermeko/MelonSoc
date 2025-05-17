# Makefile to compile RISC-V source, generate Verilog $readmemh compatible HEX file,
# and run Icarus Verilog simulation.
# All build artifacts will be placed in the BUILD_DIR directory.

# --- Toolchain Definitions ---
# 修改为您的 RISC-V GCC 工具链前缀
CROSS_COMPILE ?= riscv64-unknown-elf-
CC = $(CROSS_COMPILE)gcc
OBJCOPY = $(CROSS_COMPILE)objcopy
# 如果 'python3' 命令找不到，请尝试将其改为 'python'
# 前提是 'python' 命令指向 Python 3.x 版本且在系统 PATH 中
PYTHON = python

# --- Verilog Simulation Tools ---
IVERILOG = iverilog
VVP = vvp
SIM_OUTPUT = build/a.out # iverilog 默认输出文件名

# --- Source and Target Files ---
# 请确保 TARGET_NAME 的值后面没有多余的空格
TARGET_NAME = program
_S = program/$(TARGET_NAME).s       # 您的汇编源文件
# _C = program/$(TARGET_NAME).c     # 如果是 C 源文件
LINKER_SCRIPT = program/linker.ld      # 链接脚本路径

# Verilog 源文件 (假设在 Makefile 同级目录)
VERILOG_SOURCES = top.v bench_iverilog.v mem.v clockworks.v cpu.v
# VERILOG_SOURCES = verilog/top.v verilog/bench_iverilog.v ... # 如果 Verilog 文件在子目录

# --- Build Directory ---
BUILD_DIR = build

# --- Target File Definitions (for RISC-V build) ---
# 这些变量定义了构建产物的完整路径和名称
TARGET_ELF = $(BUILD_DIR)/$(TARGET_NAME).elf
TARGET_BIN = $(BUILD_DIR)/$(TARGET_NAME).bin
TARGET_HEX = $(BUILD_DIR)/$(TARGET_NAME).hex

# --- GCC Flags ---
ARCH_FLAGS = -march=rv32i -mabi=ilp32
CFLAGS_COMMON = $(ARCH_FLAGS) -nostdlib -nostartfiles
CFLAGS_S = $(CFLAGS_COMMON)
# CFLAGS_C = $(CFLAGS_COMMON) -O2 -Wall # For C files

LDFLAGS = -Wl,-T$(LINKER_SCRIPT) # Remove if linker script is not used

# --- Icarus Verilog Flags ---
IVERILOG_FLAGS = -DBENCH -DFREQ_DIV=0
# 如果 iverilog 编译的输出文件名不是 a.out，可以在这里指定 -o $(BUILD_DIR)/my_sim_output
# 然后 VVP 命令也需要相应修改

# --- Python Script ---
# 确保此路径正确
BIN2HEX_SCRIPT = program/bin_to_verilog_hex.py

# --- Phony Targets (targets that don't produce files with their name) ---
.PHONY: all build clean dirs simulate

# --- Default Target ---
all: 
	@echo "Must select a target" 

# --- Create Build Directory Target ---
# 这个目标确保构建目录存在
# !!! 下一行以 TAB 开头 !!!
dirs:
	@echo "Ensuring build directory $(BUILD_DIR) exists..."
	@mkdir -p $(BUILD_DIR)

# --- Build Target (for RISC-V program to HEX) ---
# 明确指出 build 依赖于最终输出文件 $(TARGET_HEX)，而不是额外的步骤
# Make 会自动根据依赖链检查是否需要重新构建
build: $(TARGET_HEX)
	@echo "Build complete. Final HEX file: $(TARGET_HEX)"

# --- Rule to create ELF file from Assembly source ---
# 这个规则确保只有当 $(_S) 或 $(LINKER_SCRIPT) 有变化时才会重新编译
$(TARGET_ELF): $(_S) $(LINKER_SCRIPT) | dirs
	@echo "Compiling and Linking $(_S) to $@"
	$(CC) $(CFLAGS_S) $(LDFLAGS) $(_S) -o $@

# --- Rule to create ELF file from C source (if you switch to C) ---
# $(TARGET_ELF): $(_C) $(LINKER_SCRIPT) dirs
# !!! 下面的配方行必须以 TAB 开头 !!!
#	@echo "Compiling and Linking $(_C) to $@"
#	$(CC) $(CFLAGS_C) $(LDFLAGS) $(_C) -o $@

# --- Rule to create Binary file from ELF file ---
# !!! 下面的配方行必须以 TAB 开头 !!!
$(TARGET_BIN): $(TARGET_ELF) dirs
	@echo "Converting $< to $@"
	$(OBJCOPY) -O binary $< $@

# --- Rule to create Verilog HEX file from Binary file ---
# !!! 下面的配方行必须以 TAB 开头 !!!
$(TARGET_HEX): $(TARGET_BIN) $(BIN2HEX_SCRIPT) dirs
	@echo "Converting $< to $@ using $(BIN2HEX_SCRIPT)"
	$(PYTHON) $(BIN2HEX_SCRIPT) $< > $@

# --- Simulate Target (for Verilog simulation) ---
# 注意：如果您的仿真需要由 'make build' 生成的 program.hex 文件，
# 那么 simulate 目标应该依赖于 $(TARGET_HEX) 或者 build。
# 例如: simulate: $(TARGET_HEX) $(VERILOG_SOURCES)
# 这里假设仿真可以独立运行，或者 program.hex 已存在。
# !!! 下面的配方行必须以 TAB 开头 !!!
simulate: build $(VERILOG_SOURCES)
	@echo "Compiling Verilog sources for simulation..."
	$(IVERILOG) $(IVERILOG_FLAGS) -o $(SIM_OUTPUT) $(VERILOG_SOURCES)
	@echo "Running simulation..."
	$(VVP) $(SIM_OUTPUT)
	@echo "Simulation finished."

# --- Clean Target ---
# 用于删除生成的文件和构建目录
# !!! 下面的配方行必须以 TAB 开头 !!!
clean:
	@echo "Cleaning up generated files and directory..."
	rm -rf $(BUILD_DIR) $(TARGET_NAME).elf $(TARGET_NAME).bin $(TARGET_NAME).hex .elf .bin .hex 
	rm -f $(SIM_OUTPUT) 
	@echo "Cleanup complete."

