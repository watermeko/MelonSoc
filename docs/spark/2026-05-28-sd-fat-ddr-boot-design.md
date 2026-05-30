# SD FAT32 DDR Boot Design

## Goal

Boot the SoC from a program stored on an SD card image by reading `BOOT.BIN` from the FAT32 root directory, copying it into DDR at `0x80000000`, and transferring execution to that DDR address.

The existing SPI-mode SD software path does not need to remain compatible. The SD boot path will use a native SD host interface so simulation can reuse `src/sim/sd_fake.v`.

## Current Context

- The SoC already has a data bus path to DDR at `0x80000000`.
- The instruction path currently fetches only from the internal PROGROM, so executing code from DDR requires an instruction fetch path to DDR.
- The current SD card driver is SPI-mode software over the SPI MMIO peripheral.
- `src/sim/sd_fake.v` models a native SDHC card interface with `sdclk`, `sdcmd`, and `sddat[3:0]`, not SPI.
- The boot program and application currently link into internal PROGROM/DATARAM using `program/boot/linker_pipeline.ld`.

## Scope

In scope:

- Add a native SD host MMIO peripheral.
- Replace the SD card software driver with a native SD block driver.
- Add simulation wiring for `sd_fake.v` and a FAT32 card image backing store.
- Add a minimal read-only FAT32 loader for root-directory `BOOT.BIN`.
- Add DDR instruction fetch support.
- Add a DDR-linked application build artifact that produces `BOOT.BIN`.
- Verify the full simulation path from SD image to DDR execution.

Out of scope:

- SD card writes.
- FAT long file names.
- Subdirectories or configurable boot paths.
- ELF parsing.
- Dynamic entry addresses.
- DMA or interrupt-driven SD transfers.
- Preserving the old SPI SD driver behavior.

## Architecture

The boot chain is split into five layers:

1. Native SD host RTL exposes a small MMIO command/data interface.
2. Native SD block driver initializes the card and reads 512-byte sectors.
3. FAT32 loader finds `BOOT.BIN` in the root directory and reads its cluster chain.
4. Bootloader copies the file into DDR at `0x80000000`.
5. CPU instruction fetch supports DDR addresses so the bootloader can jump to the loaded program.

The old SPI peripheral may stay in the SoC for other uses, but SD boot does not depend on it.

## Native SD Host RTL

Add an SD host peripheral connected to SoC MMIO and top-level pins:

- `sdclk`
- `sdcmd`
- `sddat[3:0]`

The first implementation should support only the minimum command set needed for a read-only SDHC boot path:

- CMD0: reset card
- CMD8: voltage check
- CMD55 + ACMD41: initialize card
- CMD2: read CID
- CMD3: get RCA
- CMD7: select card
- CMD16: set block length, harmless for compatibility
- CMD17: read one 512-byte block

Use 1-bit data mode first. Do not add 4-bit mode until the 1-bit boot path works.

The software-facing MMIO contract should be simple:

- command index
- command argument
- command start/status
- response registers
- read data FIFO or buffer window
- error/status bits for timeout and command/data completion

Software should poll status. DMA and interrupts are unnecessary for the first boot path.

## Simulation Model

Add `src/sim/sd_fake.v` to the Verilator build and connect it to the SoC native SD pins.

Provide a simulation RAM behind `sd_fake.v`:

- `rdaddr` selects a 16-bit word in the card image.
- `rddata` returns the corresponding 16-bit data.
- The RAM contents come from a generated FAT32 image file.

The FAT32 image should contain `BOOT.BIN` in the root directory. This keeps simulation close to the intended hardware behavior instead of using fixed LBA shortcuts.

## Software Loader

Replace the current SPI-based `sdcard.c/.h` implementation with a native SD block driver that provides:

```c
int sdcard_init(void);
int sdcard_read_block(uint32_t lba, uint8_t out512[512]);
uint8_t sdcard_last_error(void);
```

The FAT32 loader should:

- read the partition or boot sector,
- parse the FAT32 BPB,
- compute FAT start, data start, sectors per cluster, and root cluster,
- scan only the root directory,
- match the 8.3 short name `BOOT    BIN`,
- read the FAT chain for that file,
- copy file bytes sequentially to DDR.

The loader should stop after the file size from the directory entry. It does not need to support long names, deleted entries beyond skipping them, subdirectories, or fragmented-file optimization.

## DDR Execution

The current data bus can access DDR, but instruction fetch cannot. Add an instruction fetch route for DDR addresses.

Expected behavior:

- PC below the DDR window continues to fetch from PROGROM.
- PC at or above `0x80000000` fetches through the DDR bridge.
- Fetch stalls until DDR data is returned.
- Existing compressed-instruction handling still receives aligned 32-bit fetch words.

This is required before a jump to `0x80000000` can work.

## Build Outputs

Keep the internal bootloader linked for PROGROM/DATARAM.

Add a separate DDR application build path:

- link application text/data for `0x80000000`,
- produce a flat `BOOT.BIN`,
- place `BOOT.BIN` into the FAT32 card image used by simulation.

The first DDR app can be a small program that initializes UART and prints a clear message after the bootloader jumps to it.

## Bootloader Flow

The internal bootloader should:

1. initialize UART and timer enough for diagnostics,
2. initialize the native SD host,
3. mount/read FAT32 metadata,
4. find `BOOT.BIN`,
5. copy it to `0x80000000`,
6. cleanly transfer execution to `0x80000000`.

Before jumping, the bootloader should avoid leaving pending interrupts enabled. The first version can run without enabling interrupts at all.

## Verification

Use the project simulation flow:

```bash
wsl make simulate SIM_CMD="..."
```

The verification path should cover:

- SD host can initialize `sd_fake.v`.
- CMD17 can read known sectors from the FAT32 image.
- FAT32 code finds root-directory `BOOT.BIN`.
- Loader copies the expected byte count to DDR.
- CPU jumps to DDR and executes the DDR-linked program.
- UART output shows both bootloader progress and the loaded program's message.

## Acceptance Criteria

The work is ready when simulation demonstrates:

- a FAT32 SD image with root `BOOT.BIN` is loaded by `sd_fake.v`,
- the bootloader finds `BOOT.BIN` without fixed LBA knowledge,
- the file is copied into DDR at `0x80000000`,
- the CPU fetches and executes from DDR,
- the loaded program prints a distinct UART message.

