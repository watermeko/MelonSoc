CROSS_COMPILE ?= riscv64-unknown-elf-
CC = $(CROSS_COMPILE)gcc
OBJCOPY = $(CROSS_COMPILE)objcopy
SIZE = $(CROSS_COMPILE)size

HOST_CC = gcc
HOST_CXX ?= g++

KCONFIG_FILE    = Kconfig
KCONFIG_CONFIG ?= .config
AUTOCONF_H      = $(BUILD_DIR)/include/autoconf.h

KCONFIGLIB_DIR  = /usr/lib/python3/dist-packages
KCONFIG_ALLDEF  = python3 $(KCONFIGLIB_DIR)/alldefconfig.py
KCONFIG_GEN     = python3 $(KCONFIGLIB_DIR)/genconfig.py
KCONFIG_MENU    = python3 $(KCONFIGLIB_DIR)/menuconfig.py
KCONFIG_GUI     = python3 $(KCONFIGLIB_DIR)/guiconfig.py

-include $(KCONFIG_CONFIG)

CONFIG_APP_TEST_M     ?= y
CONFIG_APP_TEST_CSR   ?= y
CONFIG_APP_TEST_IRQ   ?= y
CONFIG_APP_TEST_MSIP  ?= y
CONFIG_APP_TEST_MTIME ?= y

RTL_DIR = rtl
SIM_DIR = sim
RTL_SOURCES = $(addprefix $(RTL_DIR)/, soc.sv top.v)
SIM_CPP = $(SIM_DIR)/bench.cpp
SIM_CPP_ABS = $(abspath $(SIM_CPP))
SIM_ARGS ?=

TARGET_NAME = program
_S = program/boot/$(TARGET_NAME).s
_C_SOURCES = program/utils/print.c \
             program/app/main.c \
             program/drivers/uart.c \
             program/drivers/gpio.c \
             program/drivers/i2c.c \
             program/drivers/timer.c \
             program/drivers/spi.c \
             program/drivers/sdcard.c \
             program/app/raystones.c \
             program/app/test_rtos.c \
             program/drivers/ddr.c \
             program/FreeRTOS/list.c \
             program/FreeRTOS/queue.c \
             program/FreeRTOS/tasks.c \
             program/FreeRTOS/portable/MemMang/heap_4.c \
             program/FreeRTOS/portable/GCC/RISC-V/port.c

ifneq ($(filter y,$(CONFIG_APP_TEST_CSR) $(CONFIG_APP_TEST_IRQ) $(CONFIG_APP_TEST_MTIME) $(CONFIG_APP_TEST_MSIP)),)
_C_SOURCES += program/app/test_csr.c
endif

ifeq ($(CONFIG_APP_TEST_MSIP),y)
_C_SOURCES += program/app/test_msip.c
endif

_S_UPPER_SOURCES = program/FreeRTOS/portable/GCC/RISC-V/portASM.S
LINKER_SCRIPT = program/boot/linker_pipeline.ld      

BIN2HEX_C_SRC = program/tools/bin_to_verilog_hex.c

VERILOG_SOURCES = $(RTL_SOURCES)
BUILD_DIR = build
VLT_MDIR = $(BUILD_DIR)/obj_dir

TARGET_ELF = $(BUILD_DIR)/$(TARGET_NAME).elf
TARGET_BIN = $(BUILD_DIR)/$(TARGET_NAME).bin
TARGET_HEX = $(BUILD_DIR)/$(TARGET_NAME).hex
TARGET_TEXT_BIN = $(BUILD_DIR)/program_text.bin
TARGET_DATA_BIN = $(BUILD_DIR)/program_data.bin
TARGET_PROGROM_HEX = $(BUILD_DIR)/PROGROM.hex
TARGET_DATARAM_HEX = $(BUILD_DIR)/DATARAM.hex

BIN2HEX_UTIL_NAME = bin_to_verilog_hex
ifeq ($(OS),Windows_NT)
    BIN2HEX_EXECUTABLE = $(BUILD_DIR)/$(BIN2HEX_UTIL_NAME).exe
else
    BIN2HEX_EXECUTABLE = $(BUILD_DIR)/$(BIN2HEX_UTIL_NAME)
endif

# CPU supports RV32I + M + C (RVC is decompressed in the frontend).
ARCH_FLAGS = -march=rv32imc_zicsr -mabi=ilp32
PICOLIBC_PREFIX ?= /usr/lib/picolibc/riscv64-unknown-elf
PICOLIBC_INCLUDE_DIR = $(PICOLIBC_PREFIX)/include
CFLAGS_COMMON = $(ARCH_FLAGS) -ffreestanding -flto -isystem $(PICOLIBC_INCLUDE_DIR)
FREERTOS_INCLUDE = \
    -Iprogram/FreeRTOS \
    -Iprogram/FreeRTOS/include \
    -Iprogram/FreeRTOS/portable/GCC/RISC-V \
    -Iprogram/FreeRTOS/portable/GCC/RISC-V/chip_specific_extensions/RV32I_CLINT_no_extensions

CFLAGS_S = $(CFLAGS_COMMON)
CFLAGS_C = $(CFLAGS_COMMON) -Os -Wall -fsingle-precision-constant -fno-inline-functions \
           -ffunction-sections -fdata-sections \
           -Iprogram/drivers -Iprogram/utils -Iprogram/app -Iprogram/boot \
           -I$(BUILD_DIR)/include \
           $(FREERTOS_INCLUDE)

LDFLAGS = -nostartfiles -T$(LINKER_SCRIPT) --specs=picolibc.specs -Wl,--gc-sections -flto
LIBS = -lc -lm -lgcc

.PHONY: all build clean dirs simulate menuconfig guiconfig defconfig

all:
	@echo "Must select a target"

dirs:
	@mkdir -p $(BUILD_DIR)

$(KCONFIG_CONFIG):
	@echo "No .config found — generating defaults..."
	$(KCONFIG_ALLDEF) $(KCONFIG_FILE)

$(AUTOCONF_H): $(KCONFIG_CONFIG) | dirs
	@mkdir -p $(dir $(AUTOCONF_H))
	$(KCONFIG_GEN) --header-path $(AUTOCONF_H) $(KCONFIG_FILE)

menuconfig: $(KCONFIG_CONFIG)
	$(KCONFIG_MENU) $(KCONFIG_FILE)
	@$(MAKE) $(AUTOCONF_H)

guiconfig: $(KCONFIG_CONFIG)
	$(KCONFIG_GUI) $(KCONFIG_FILE)
	@$(MAKE) $(AUTOCONF_H)

defconfig:
	$(KCONFIG_ALLDEF) $(KCONFIG_FILE)
	@$(MAKE) $(AUTOCONF_H)

build: $(AUTOCONF_H) $(TARGET_PROGROM_HEX) $(TARGET_DATARAM_HEX)
	@echo "Build complete!"
	@echo "  PROGROM: $(TARGET_PROGROM_HEX)"
	@echo "  DATARAM: $(TARGET_DATARAM_HEX)"

$(BIN2HEX_EXECUTABLE): $(BIN2HEX_C_SRC) | dirs
	@echo "Compiling host utility: $< -> $@"
	$(HOST_CC) $< -o $@

_C_OBJS = $(patsubst program/%.c,$(BUILD_DIR)/%.o,$(_C_SOURCES))
_S_OBJS = $(patsubst program/%.s,$(BUILD_DIR)/%.o,$(_S))
_S_UPPER_OBJS = $(patsubst program/%.S,$(BUILD_DIR)/%.o,$(_S_UPPER_SOURCES))
OBJS = $(_C_OBJS) $(_S_OBJS) $(_S_UPPER_OBJS)

$(TARGET_ELF): $(OBJS) $(LINKER_SCRIPT) | dirs
	@echo "Linking object files to $@"
	$(CC) $(ARCH_FLAGS) $(LDFLAGS) $(OBJS) $(LIBS) -o $@
	@echo ""
	@echo "=== Program Size and Memory Usage ==="
	@$(SIZE) -A $@
	@echo ""
	@$(SIZE) -B $@
	@echo ""
	@echo "=== Memory Utilization (32KB each) ==="
	@$(SIZE) -A $@ | awk ' \
		BEGIN { text=0; data=0; rodata=0; bss=0 } \
		/^\.text/ { text=$$2 } \
		/^\.data/ { data=$$2 } \
		/^\.rodata/ { rodata=$$2 } \
		/^\.bss/ { bss=$$2 } \
		END { \
			progrom_used = text; \
			dataram_used = data + rodata; \
			progrom_percent = (progrom_used/32768)*100; \
			dataram_percent = (dataram_used/32768)*100; \
			ram_used = data + rodata + bss; \
			ram_percent = (ram_used/32768)*100; \
			printf "PROGROM (.text):         %6d / 32768 bytes (%5.2f%%)\n", progrom_used, progrom_percent; \
			printf "DATARAM (.data+.rodata): %6d / 32768 bytes (%5.2f%%)\n", dataram_used, dataram_percent; \
			printf "RAM usage (data+bss):    %6d / 32768 bytes (%5.2f%%)\n", ram_used, ram_percent; \
		}'
	@echo "========================================"
	@echo ""

$(BUILD_DIR)/%.o: program/%.c $(AUTOCONF_H) | dirs
	@mkdir -p $(dir $@)
	@echo "Compiling C source: $< -> $@"
	$(CC) $(CFLAGS_C) -c $< -o $@

$(BUILD_DIR)/%.o: program/%.s | dirs
	@mkdir -p $(dir $@)
	@echo "Assembling: $< -> $@"
	$(CC) $(CFLAGS_S) -c $< -o $@

# 将预处理汇编源文件（.S）汇编为目标文件（需要C预处理器展开宏）
$(BUILD_DIR)/%.o: program/%.S | dirs
	@mkdir -p $(dir $@)
	@echo "Assembling (preprocessed): $< -> $@"
	$(CC) $(CFLAGS_S) $(FREERTOS_INCLUDE) -c $< -o $@

$(TARGET_BIN): $(TARGET_ELF) dirs
	@echo "Converting $< to $@"
	$(OBJCOPY) -O binary $< $@

$(TARGET_HEX): $(TARGET_BIN) $(BIN2HEX_EXECUTABLE) | dirs
	@echo "Converting $< to $@ using $(BIN2HEX_EXECUTABLE)"
	$(BIN2HEX_EXECUTABLE) $< > $@

# 提取 .text 段 (指令存储器)
$(TARGET_TEXT_BIN): $(TARGET_ELF) | dirs
	@echo "Extracting .text section to $@"
	$(OBJCOPY) -O binary --only-section=.text $< $@

# 提取 .rodata 和 .data 段 (数据存储器)
$(TARGET_DATA_BIN): $(TARGET_ELF) | dirs
	@echo "Extracting .rodata and .data sections to $@"
	$(OBJCOPY) -O binary --only-section=.rodata --only-section=.data $< $@
	@if [ ! -s $@ ]; then echo "Warning: .rodata and .data sections are empty, creating minimal file"; touch $@; fi

# 转换为 PROGROM.hex
$(TARGET_PROGROM_HEX): $(TARGET_TEXT_BIN) $(BIN2HEX_EXECUTABLE) | dirs
	@echo "Converting $< to $@"
	$(BIN2HEX_EXECUTABLE) $< > $@
	@echo "  Lines in PROGROM.hex: $$(wc -l < $@)"

# 转换为 DATARAM.hex
$(TARGET_DATARAM_HEX): $(TARGET_DATA_BIN) $(BIN2HEX_EXECUTABLE) | dirs
	@echo "Converting $< to $@"
	@if [ -s $< ]; then \
		$(BIN2HEX_EXECUTABLE) $< > $@; \
	else \
		echo "00000000" > $@; \
	fi
	@echo "  Lines in DATARAM.hex: $$(wc -l < $@)"

load:
	@echo "Loading bitstream to FPGA SRAM..."
	openFPGALoader -c ft2232 -b tangprimer20k ../impl/pnr/melon-riscv.fs
	@echo "Load complete."

load_flash:
	@echo "Flashing bitstream to FPGA flash..."
	openFPGALoader -c ft2232 -b tangprimer20k -f ../impl/pnr/melon-riscv.fs
	@echo "Flash complete."

simulate: build $(VERILOG_SOURCES) $(SIM_CPP)
	@echo "Running Verilator to compile Verilog sources..."
	@mkdir -p $(VLT_MDIR)
	verilator -sv -I$(RTL_DIR) -I$(RTL_DIR)/lib -DBENCH -Wno-fatal --top-module SOC -cc -exe $(SIM_CPP_ABS) $(VERILOG_SOURCES) --Mdir $(VLT_MDIR) --bbox-unsup
	@echo "Building Verilator simulation executable..."
	@command -v $(HOST_CXX) >/dev/null 2>&1 || (echo "Error: need a C++ compiler (set HOST_CXX=clang++ or install g++)"; exit 1)
	@echo 'int main(){return 0;}' | $(HOST_CXX) -x c++ - -o /tmp/melonsoc_cxx_test >/dev/null 2>&1 || (echo "Error: $(HOST_CXX) cannot compile C++ (missing cc1plus/libstdc++?). Install g++/clang++ and rerun."; exit 1)
	@rm -f /tmp/melonsoc_cxx_test
	$(MAKE) -C $(VLT_MDIR) -f VSOC.mk CXX=$(HOST_CXX)
	@echo "Running Verilator simulation..."
	./$(VLT_MDIR)/VSOC $(SIM_ARGS)
	@echo "Verilator simulation finished."

clean:
	@echo "Cleaning up generated files and directories..."
	rm -rf $(BUILD_DIR) $(TARGET_NAME).elf $(TARGET_NAME).bin $(TARGET_NAME).hex .elf .bin .hex obj_dir
	@echo "Cleanup complete."

