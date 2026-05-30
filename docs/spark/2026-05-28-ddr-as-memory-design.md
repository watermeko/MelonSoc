# DDR as Memory Design

## Goal

Make DDR accessible as normal CPU data memory instead of a DDR-specific MMIO peripheral.

The first implementation keeps the current boot model: instructions still execute from on-chip PROGROM, and the existing DATARAM continues to hold the linked `.rodata`, `.data`, `.bss`, heap, and stack. DDR is added as a separate data-memory window at `0x8000_0000`, accessed with ordinary RISC-V load/store instructions.

## Scope

In scope:

- Replace the internal CPU data `simple_bus_if` path with a Wishbone-style bus.
- Use Wishbone handshaking for on-chip RAM, MMIO peripherals, and DDR.
- Map DDR at `0x8000_0000`.
- Remove the old DDR MMIO register block and software DDR MMIO driver.
- Add a simulation DDR app model sufficient for load/store tests.

Out of scope:

- Moving `.data`, `.bss`, heap, or stack to DDR.
- Executing instructions from DDR.
- Adding caches, bursts, DMA, multiple outstanding requests, or bus arbitration between multiple masters.
- Adding DDR status or error MMIO registers.

## Address Map

| Range | Purpose |
| --- | --- |
| `0x0000_0000` | On-chip PROGROM, instruction fetch boot path |
| `0x0001_0000` | On-chip DATARAM, current linked data/stack memory |
| `0x0040_0000` | MMIO peripherals: GPIO, UART, I2C, timer, SPI, CLINT |
| `0x8000_0000` | DDR data-memory window |

The existing DDR MMIO block at `0x0040_0100` is removed. Software no longer talks to DDR by writing controller registers; it dereferences normal pointers in the DDR window.

## Internal Bus

Replace `simple_bus_if` for the CPU data path with a Wishbone-style interface:

- `adr`: byte address
- `dat_w`: write data
- `dat_r`: read data
- `sel`: byte lane select
- `we`: write enable
- `cyc`: transaction active
- `stb`: request valid
- `ack`: request completed
- `stall`: slave or interconnect cannot accept the request this cycle

All data-side slaves use this handshake, including DATARAM and MMIO. DATARAM and simple MMIO peripherals may acknowledge quickly, but they should still express completion through `ack` rather than relying on an implicit fixed latency.

The instruction fetch path can remain on the existing instruction interface for this scope because DDR is not executable memory and PROGROM boot behavior is unchanged.

## CPU Behavior

The CPU data MEM stage issues one Wishbone transaction for each load/store.

While a load/store transaction is pending, the CPU freezes the pipeline stages that could otherwise retire or overwrite the in-flight memory operation. When `ack` arrives:

- load captures `dat_r`, formats byte/halfword/word data according to `funct3`, and proceeds to writeback;
- store is considered complete and can retire without register writeback.

The first implementation supports only one outstanding data transaction. This matches the current in-order pipeline and avoids adding reorder, buffering, or cache behavior.

## SoC Decode

The SoC data interconnect decodes the CPU Wishbone master address and forwards each transaction to exactly one slave:

- DATARAM for the on-chip RAM range,
- MMIO interconnect for the existing peripheral range,
- DDR bridge for the DDR range.

The interconnect multiplexes the selected slave's `dat_r`, `ack`, and `stall` back to the CPU. Unmapped addresses complete with `ack` and `dat_r = 0`, following the current simple SoC style without adding a CPU exception mechanism.

## MMIO Peripherals

Existing MMIO peripherals are converted from `simple_bus_if` to the Wishbone interface. Each peripheral acknowledges accesses through `ack` and returns read data through `dat_r`.

The old `ddr3_app_mmio` peripheral is deleted from the MMIO decode. Its address constants are removed from the RTL package, and software headers/source files for DDR MMIO access are removed from the build.

## DDR Wishbone Bridge

The DDR bridge is a Wishbone slave on the `0x8000_0000` window and a master of the Gowin DDR app interface.

The Gowin app port is 128 bits wide, while the CPU data bus is 32 bits wide. The bridge translates each Wishbone access into a 16-byte-aligned DDR app operation:

- 32-bit load: read the aligned 128-bit line, select the requested 32-bit word, return it on `dat_r`, then assert `ack`.
- byte/halfword/word store: read the aligned 128-bit line, merge the selected bytes using Wishbone `sel`, write the updated 128-bit line back, then assert `ack`.

The bridge waits for DDR initialization before completing requests. A CPU access to DDR before calibration completes remains pending; no status register or timeout is added.

The first version handles one transaction at a time. It does not combine adjacent accesses, expose burst controls to software, or keep a cache line buffer visible across requests.

## Software Impact

Software accesses DDR with normal volatile pointers, for example a test may use `volatile uint32_t *p = (volatile uint32_t *)0x80000000u`.

Remove:

- `src/program/drivers/ddr.c`
- `src/program/drivers/ddr.h`
- DDR driver references from the program build

Keep the linker script and boot stack placement unchanged. Moving heap or stack into DDR is a separate design because it changes boot ordering and failure behavior.

## Simulation

The Verilator bench needs a minimal DDR app model because the current bench ties DDR readiness and calibration low.

The model should:

- assert `ddr_init_calib_complete`;
- assert command/data readiness according to the app protocol;
- store 128-bit lines in a simulation array;
- return read data with `ddr_app_rdata_valid` and `ddr_app_rdata_end`.

This model only needs to support the single-request bridge behavior described above.

## Testing

Run tests with the project convention:

```sh
wsl make simulate SIM_CMD="..."
```

Required coverage:

- DDR word store then word load from `0x8000_0000`.
- DDR byte and halfword stores using normal C accesses, then word or byte/halfword loads to verify `sel` merge behavior.
- Existing non-DDR UART or RTOS smoke test to confirm Wishbone conversion did not break DATARAM/MMIO boot behavior.
- Source search confirming no active `simple_bus_if` data path or DDR MMIO decode remains.

## Acceptance Criteria

- CPU load/store instructions can read and write DDR through `0x8000_0000`.
- DDR is not exposed through MMIO registers.
- On-chip DATARAM and MMIO peripherals use Wishbone handshakes.
- Existing PROGROM boot and DATARAM-linked software still run.
- DDR load/store simulation passes with the new bench model.
