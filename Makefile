.DEFAULT_GOAL := help

SRC_MAKE := $(MAKE) -C src

.PHONY: help all \
    build clean dirs simulate load load_flash \
    build_fpga build_fpga_all build_fpga_syn build_fpga_pnr \
    src-%

help:
	@echo "Available targets:"
	@echo "  build          - Build the project"
	@echo "  clean          - Clean build artifacts"
	@echo "  dirs           - Create necessary directories"
	@echo "  simulate       - Run simulations"
	@echo "  load           - Load the design onto the FPGA"
	@echo "  load_flash     - Load the design into flash memory"
	@echo "  build_fpga     - Build FPGA bitstream via gw_sh (STAGE=all|syn|pnr, default: all)"
	@echo "  terminal       - Open serial terminal to the FPGA board"

all: help

build clean dirs simulate load load_flash:
	@$(SRC_MAKE) $@

build_fpga:
	@stage="$(STAGE)"; \
	[ -n "$$stage" ] || stage="all"; \
	case "$$stage" in all|syn|pnr) ;; *) echo "Invalid STAGE=$$stage (use: all|syn|pnr)"; exit 2;; esac; \
	script="gw_script_$$stage.tcl"; \
	echo "open_project melon-riscv.gprj\nrun $$stage" > "$$script"; \
	LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libfreetype.so.6 QT_QPA_PLATFORM=minimal gw_sh "$$script"; \
	rm -f "$$script"

terminal:
	picocom -b 115200 --imap lfcrlf,crcrlf --omap delbs,crlf --flow n /dev/ttyUSB1

