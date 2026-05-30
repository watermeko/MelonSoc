CROSS_COMPILE ?= riscv64-unknown-elf-
CC = $(CROSS_COMPILE)gcc
OBJCOPY = $(CROSS_COMPILE)objcopy
SIZE = $(CROSS_COMPILE)size

HOST_CC = gcc
HOST_CXX ?= g++

KCONFIG_FILE    = Kconfig
KCONFIG_CONFIG ?= .config
AUTOCONF_H      = $(BUILD_DIR)/include/autoconf.h

KCONFIG_ALLDEF  = alldefconfig
KCONFIG_GEN     = genconfig
KCONFIG_MENU    = menuconfig
KCONFIG_GUI     = guiconfig

$(KCONFIG_CONFIG):
	@echo "No .config found — generating defaults..."
	$(KCONFIG_ALLDEF) $(KCONFIG_FILE)

include $(KCONFIG_CONFIG)
# Auto-discover test source files from CONFIG_APP_TEST_* = y in .config
# To add a new test: 1) add CONFIG_APP_TEST_FOO to Kconfig
# 2) add "_TEST_SRC_FOO := test_foo.c" below (or reuse existing)
_TEST_ENABLED := $(foreach v,$(filter CONFIG_APP_TEST_%,$(.VARIABLES)),$(if $(filter y,$($(v))),$(patsubst CONFIG_APP_TEST_%,%,$(v))))

_TEST_SRC_CSR   := test_csr.c
_TEST_SRC_IRQ   := test_csr.c
_TEST_SRC_MTIME := test_csr.c
_TEST_SRC_MSIP  := test_msip.c

_TEST_SOURCES := $(foreach n,$(_TEST_ENABLED),$(if $(_TEST_SRC_$(n)),program/app/$(_TEST_SRC_$(n))))


RTL_DIR = rtl
SIM_DIR = sim
RTL_SOURCES = $(addprefix $(RTL_DIR)/, soc.sv top.v)
SIM_CPP = $(SIM_DIR)/bench.cpp
SIM_CPP_ABS = $(abspath $(SIM_CPP))
SIM_ARGS ?=

# Convenience: SIM_CMD=<cmd>  →  inject one shell command at startup
#   make simulate SIM_CMD="test-mtime"
# For multiple commands, repeat --sim-arg directly:
#   make simulate SIM_ARGS="--sim-arg test-mtime --sim-arg test-msip"
SIM_CMD ?=
ifneq ($(SIM_CMD),)
    SIM_ARGS += --sim-arg "$(SIM_CMD)"
endif

TARGET_NAME = program
_S = program/boot/$(TARGET_NAME).s
_C_SOURCES = program/utils/print.c \
             program/app/main.c \
             program/boot/fatboot.c \
             program/drivers/ddr.c \
             program/drivers/gpio.c \
             program/drivers/i2c.c \
             program/drivers/spi.c \
             program/drivers/uart.c \
             program/drivers/timer.c \
             program/drivers/sdcard.c \
             program/app/raystones.c

_C_SOURCES += $(sort $(_TEST_SOURCES))

_S_UPPER_SOURCES =
LINKER_SCRIPT = program/boot/linker_pipeline.ld      
DDR_LINKER_SCRIPT = program/boot/linker_ddr.ld

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
DDR_APP_ELF = $(BUILD_DIR)/ddr_app.elf
DDR_APP_TEXT_BIN = $(BUILD_DIR)/ddr_app_text.bin
DDR_APP_DATA_BIN = $(BUILD_DIR)/ddr_app_data.bin
DDR_APP_BIN = $(BUILD_DIR)/BOOT.BIN
SD_IMAGE_HEX = $(BUILD_DIR)/sd_image.hex

BIN2HEX_UTIL_NAME = bin_to_verilog_hex
ifeq ($(OS),Windows_NT)
    BIN2HEX_EXECUTABLE = $(BUILD_DIR)/$(BIN2HEX_UTIL_NAME).exe
else
    BIN2HEX_EXECUTABLE = $(BUILD_DIR)/$(BIN2HEX_UTIL_NAME)
endif

# CPU supports RV32I + M + C (RVC is decompressed in the frontend).
ARCH_FLAGS = -march=rv32imc_zicsr -mabi=ilp32
DDR_ARCH_FLAGS = -march=rv32imc_zicsr -mabi=ilp32
PICOLIBC_PREFIX ?= /usr/lib/picolibc/riscv64-unknown-elf
PICOLIBC_INCLUDE_DIR = $(PICOLIBC_PREFIX)/include
CFLAGS_COMMON = $(ARCH_FLAGS) -ffreestanding -flto -isystem $(PICOLIBC_INCLUDE_DIR)
FREERTOS_INCLUDE = \
    -Iprogram/ddr_app/FreeRTOS \
    -Iprogram/ddr_app/FreeRTOS/include \
    -Iprogram/ddr_app/FreeRTOS/portable/GCC/RISC-V \
    -Iprogram/ddr_app/FreeRTOS/portable/GCC/RISC-V/chip_specific_extensions/RV32I_CLINT_no_extensions

CFLAGS_S = $(CFLAGS_COMMON)
CFLAGS_C = $(CFLAGS_COMMON) -Os -Wall -fsingle-precision-constant -fno-inline-functions \
           -ffunction-sections -fdata-sections \
           -Iprogram/drivers -Iprogram/utils -Iprogram/app -Iprogram/ddr_app -Iprogram/boot \
           -I$(BUILD_DIR)/include \
           $(FREERTOS_INCLUDE)
DEPFLAGS = -MMD -MP

LDFLAGS = -nostartfiles -T$(LINKER_SCRIPT) --specs=picolibc.specs -Wl,--gc-sections -flto
LIBS = -lc -lm -lgcc

.PHONY: all build clean dirs simulate menuconfig guiconfig defconfig

all:
	@echo "Must select a target"

dirs:
	@mkdir -p $(BUILD_DIR)

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

build: $(AUTOCONF_H) $(TARGET_PROGROM_HEX) $(TARGET_DATARAM_HEX) $(SD_IMAGE_HEX)
	@echo "Build complete!"
	@echo "  PROGROM: $(TARGET_PROGROM_HEX)"
	@echo "  DATARAM: $(TARGET_DATARAM_HEX)"
	@echo "  SD image: $(SD_IMAGE_HEX)"

$(BIN2HEX_EXECUTABLE): $(BIN2HEX_C_SRC) | dirs
	@echo "Compiling host utility: $< -> $@"
	$(HOST_CC) $< -o $@

_C_OBJS = $(patsubst program/%.c,$(BUILD_DIR)/%.o,$(_C_SOURCES))
_S_OBJS = $(patsubst program/%.s,$(BUILD_DIR)/%.o,$(_S))
_S_UPPER_OBJS = $(patsubst program/%.S,$(BUILD_DIR)/%.o,$(_S_UPPER_SOURCES))
OBJS = $(_C_OBJS) $(_S_OBJS) $(_S_UPPER_OBJS)
DDR_APP_OBJS = $(BUILD_DIR)/ddr_app/start.o \
               $(BUILD_DIR)/ddr_app/main.o \
               $(BUILD_DIR)/ddr_app/test_rtos.o \
               $(BUILD_DIR)/ddr_app/freertos_hooks.o \
               $(BUILD_DIR)/drivers/uart.o \
               $(BUILD_DIR)/utils/print.o \
               $(BUILD_DIR)/ddr_app/FreeRTOS/list.o \
               $(BUILD_DIR)/ddr_app/FreeRTOS/queue.o \
               $(BUILD_DIR)/ddr_app/FreeRTOS/tasks.o \
               $(BUILD_DIR)/ddr_app/FreeRTOS/timers.o \
               $(BUILD_DIR)/ddr_app/FreeRTOS/portable/GCC/RISC-V/port.o \
               $(BUILD_DIR)/ddr_app/FreeRTOS/portable/GCC/RISC-V/portASM.o \
               $(BUILD_DIR)/ddr_app/FreeRTOS/portable/MemMang/heap_4.o
DEP_FILES = $(sort $(OBJS:.o=.d) $(DDR_APP_OBJS:.o=.d))

-include $(DEP_FILES)

$(TARGET_ELF): $(OBJS) $(LINKER_SCRIPT) | dirs
	@echo "Linking object files to $@"
	$(CC) $(ARCH_FLAGS) $(LDFLAGS) $(OBJS) $(LIBS) -o $@
	@echo ""

$(DDR_APP_ELF): $(DDR_APP_OBJS) $(DDR_LINKER_SCRIPT) | dirs
	@echo "Linking DDR app to $@"
	$(CC) $(DDR_ARCH_FLAGS) -nostartfiles -T$(DDR_LINKER_SCRIPT) --specs=picolibc.specs -Wl,--gc-sections -Wl,--no-relax -flto $(DDR_APP_OBJS) $(LIBS) -o $@

$(DDR_APP_TEXT_BIN): $(DDR_APP_ELF) | dirs
	@echo "Extracting DDR app .text to $@"
	$(OBJCOPY) -O binary --only-section=.text $< $@

$(DDR_APP_DATA_BIN): $(DDR_APP_ELF) | dirs
	@echo "Extracting DDR app .ramdata to $@"
	$(OBJCOPY) -O binary --only-section=.ramdata $< $@

$(DDR_APP_BIN): $(DDR_APP_TEXT_BIN) $(DDR_APP_DATA_BIN) program/tools/make_ddr_app_image.py | dirs
	@echo "Packaging DDR app image $@"
	python3 program/tools/make_ddr_app_image.py $(DDR_APP_TEXT_BIN) $(DDR_APP_DATA_BIN) $@

$(SD_IMAGE_HEX): $(DDR_APP_BIN) program/tools/make_sd_image.py | dirs
	@echo "Generating FAT32 SD image $@"
	python3 program/tools/make_sd_image.py $(DDR_APP_BIN) $@

$(BUILD_DIR)/ddr_app/start.o: program/ddr_app/start.s | dirs
	@mkdir -p $(dir $@)
	@echo "Assembling DDR app start: $< -> $@"
	$(CC) $(DDR_ARCH_FLAGS) -ffreestanding -c $< -o $@

$(BUILD_DIR)/ddr_app/main.o: program/ddr_app/main.c $(AUTOCONF_H) | dirs
	@mkdir -p $(dir $@)
	@echo "Compiling DDR app C source: $< -> $@"
	$(CC) $(CFLAGS_C) $(DEPFLAGS) -c $< -o $@

$(BUILD_DIR)/%.o: program/%.c $(AUTOCONF_H) | dirs
	@mkdir -p $(dir $@)
	@echo "Compiling C source: $< -> $@"
	$(CC) $(CFLAGS_C) $(DEPFLAGS) -c $< -o $@

$(BUILD_DIR)/%.o: program/%.s | dirs
	@mkdir -p $(dir $@)
	@echo "Assembling: $< -> $@"
	$(CC) $(CFLAGS_S) -c $< -o $@

# 将预处理汇编源文件（.S）汇编为目标文件（需要C预处理器展开宏）
$(BUILD_DIR)/%.o: program/%.S | dirs
	@mkdir -p $(dir $@)
	@echo "Assembling (preprocessed): $< -> $@"
	$(CC) $(CFLAGS_S) $(FREERTOS_INCLUDE) $(DEPFLAGS) -c $< -o $@

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
	openFPGALoader -b tangprimer20k ../impl/pnr/melon-riscv.fs
	@echo "Load complete."

load_flash:
	@echo "Flashing bitstream to FPGA flash..."
	openFPGALoader -c ft2232 -b tangprimer20k -f ../impl/pnr/melon-riscv.fs --unprotect-flash
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
