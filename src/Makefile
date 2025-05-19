CROSS_COMPILE ?= riscv64-unknown-elf-
CC = $(CROSS_COMPILE)gcc
OBJCOPY = $(CROSS_COMPILE)objcopy

HOST_CC = gcc

IVERILOG = iverilog
VVP = vvp
SIM_OUTPUT = build/a.out 

TARGET_NAME = program
_S = program/$(TARGET_NAME).s       
_C_SOURCES = program/print.c
LINKER_SCRIPT = program/linker.ld      

BIN2HEX_C_SRC = program/bin_to_verilog_hex.c 

VERILOG_SOURCES = top.v mem.v  cpu.v uart.v gowin_mult/gowin_mult.v integer_division/integer_division.vo 
BUILD_DIR = build

TARGET_ELF = $(BUILD_DIR)/$(TARGET_NAME).elf
TARGET_BIN = $(BUILD_DIR)/$(TARGET_NAME).bin
TARGET_HEX = $(BUILD_DIR)/$(TARGET_NAME).hex

BIN2HEX_UTIL_NAME = bin_to_verilog_hex
ifeq ($(OS),Windows_NT)
    BIN2HEX_EXECUTABLE = $(BUILD_DIR)/$(BIN2HEX_UTIL_NAME).exe
else
    BIN2HEX_EXECUTABLE = $(BUILD_DIR)/$(BIN2HEX_UTIL_NAME)
endif

ARCH_FLAGS = -march=rv32im -mabi=ilp32
CFLAGS_COMMON = $(ARCH_FLAGS) -nostdlib -nostartfiles
CFLAGS_S = $(CFLAGS_COMMON)
CFLAGS_C = $(CFLAGS_COMMON) -O2 -Wall -Iprogram # 取消注释并为 C 文件添加编译标志，-Iprogram 用于 program/ 目录下的头文件

LDFLAGS = -Wl,-T$(LINKER_SCRIPT) 

IVERILOG_FLAGS = -DBENCH -DFREQ_DIV=0

.PHONY: all build clean dirs simulate simulate_verilator

all: 
	@echo "Must select a target" 

dirs:
	@echo "Ensuring build directory $(BUILD_DIR) exists..."
	@mkdir -p $(BUILD_DIR)

build: $(TARGET_HEX)
	@echo "Build complete. Final HEX file: $(TARGET_HEX)"

$(BIN2HEX_EXECUTABLE): $(BIN2HEX_C_SRC) | dirs
	@echo "Compiling host utility: $< -> $@"
	$(HOST_CC) $< -o $@

# $(TARGET_ELF): $(_S) $(LINKER_SCRIPT) | dirs # 旧的 ELF 生成规则
# 	@echo "Compiling and Linking $(_S) to $@"
# 	$(CC) $(CFLAGS_S) $(LDFLAGS) $(_S) -o $@

# 从 C 和汇编源文件派生的目标文件
_C_OBJS = $(patsubst program/%.c,$(BUILD_DIR)/%.o,$(_C_SOURCES))
_S_OBJS = $(patsubst program/%.s,$(BUILD_DIR)/%.o,$(_S))
OBJS = $(_C_OBJS) $(_S_OBJS)

# 将目标文件链接到最终 ELF 可执行文件的规则
$(TARGET_ELF): $(OBJS) $(LINKER_SCRIPT) | dirs
	@echo "Linking object files to $@"
	$(CC) $(CFLAGS_COMMON) $(LDFLAGS) $(OBJS) -o $@

# 将 C 源文件编译为目标文件的规则
$(BUILD_DIR)/%.o: program/%.c | dirs
	@echo "Compiling C source: $< -> $@"
	$(CC) $(CFLAGS_C) -c $< -o $@

# 将汇编源文件汇编为目标文件的规则
$(BUILD_DIR)/%.o: program/%.s | dirs
	@echo "Assembling: $< -> $@"
	$(CC) $(CFLAGS_S) -c $< -o $@

$(TARGET_BIN): $(TARGET_ELF) dirs
	@echo "Converting $< to $@"
	$(OBJCOPY) -O binary $< $@

$(TARGET_HEX): $(TARGET_BIN) $(BIN2HEX_EXECUTABLE) | dirs
	@echo "Converting $< to $@ using $(BIN2HEX_EXECUTABLE)"
	$(BIN2HEX_EXECUTABLE) $< > $@

load:
	@echo "Loading bitstream to FPGA SRAM..."
	openFPGALoader -c ft2232 -b tangprimer20k ../impl/pnr/melon-riscv.fs
	@echo "Load complete."

load_flash:
	@echo "Flashing bitstream to FPGA flash..."
	openFPGALoader -c ft2232 -b tangprimer20k -f ../impl/pnr/melon-riscv.fs
	@echo "Flash complete."

simulate: build $(VERILOG_SOURCES)
	@echo "Compiling Verilog sources for simulation..."
	$(IVERILOG) $(IVERILOG_FLAGS) -o $(SIM_OUTPUT) $(VERILOG_SOURCES) bench_iverilog.v -lprim_sim.v
	@echo "Running simulation..."
	$(VVP) $(SIM_OUTPUT)
	@echo "Simulation finished."

simulate_verilator: build $(VERILOG_SOURCES) bench.cpp
	@echo "Running Verilator to compile Verilog sources..."
	verilator -DBENCH -Wno-fatal --top-module SOC -cc -exe bench.cpp $(VERILOG_SOURCES) prim_sim.v --Mdir obj_dir --bbox-unsup
	@echo "Building Verilator simulation executable..."
	$(MAKE) -C obj_dir -f VSOC.mk
	@echo "Running Verilator simulation..."
	./obj_dir/VSOC
	@echo "Verilator simulation finished."

clean:
	@echo "Cleaning up generated files and directories..."
	rm -rf $(BUILD_DIR) $(TARGET_NAME).elf $(TARGET_NAME).bin $(TARGET_NAME).hex .elf .bin .hex obj_dir
	rm -f $(SIM_OUTPUT) 
	@echo "Cleanup complete."

