# AXI4 DMA

A DMA controller that copies a block of memory from one place to another without
the CPU touching the data. The CPU writes a source address, a destination
address and a length, presses start, and gets an interrupt when the copy is done.

The read side and the write side run on different clocks. The intended setup is
a source in the SoC clock domain (an SRAM) and a destination in the DDR
controller's clock domain.

## How it works

```
                 clk_rd domain                          clk_wr domain
        +------------------------------+        +---------------------------+
CPU --> | AXI4-Lite regs  --> irq      |        |                           |
        |      |                       |        |                           |
        |  read engine --> AXI4 master | -> src |                           |
        |      |                       |        |                           |
        |      +--> async FIFO write ==========> async FIFO read             |
        |                              |        |      |                    |
        |                              |        | write engine --> AXI4 master -> dst
        +------------------------------+        +---------------------------+
```

1. Software writes `SRC`, `DST` and `LEN`, then sets the START bit in `CTRL`.
2. The read engine splits the source range into AXI4 INCR bursts (up to 16
   beats of 8 bytes) and pushes the returned data into the async FIFO.
3. The write engine, on the other clock, pops the FIFO and writes the data to
   the destination as bursts.
4. After the last write response, the write engine tells the register block it
   is done. `STATUS` and `IRQ_STATUS` are updated and the `irq` pin goes high if
   it is enabled.

Bursts are split so they never cross a 4KB boundary, which AXI4 requires.

### Clock domain crossings

There are three crossings:

| What | How |
|------|-----|
| Data, read side to write side | Gray-code async FIFO (`async_fifo.sv`, 32 entries by default) |
| START, register block to write engine | Toggle + 2-flop synchronizer (`cdc_pulse.sv`) |
| DONE, write engine back to register block | Same toggle synchronizer, plus a 2-flop sync on the write error flag |

`SRC`, `DST` and `LEN` go to the write engine as plain wires. This is safe
because the register block ignores writes to them while a transfer is busy, so
they do not change around the START pulse.

### Interrupt

`irq` is a level output: `irq = |(IRQ_STATUS & IRQ_EN)`.

- Bit 0 (done) is set when a transfer finishes.
- Bit 1 (error) is set when the config is bad (zero length, or an address or
  length that is not a multiple of 8) or when either AXI master gets an error
  response.

`IRQ_STATUS` is write-1-to-clear. If the interrupt is masked in `IRQ_EN`, the
status bit still sets and only the pin stays low, so software can poll instead.
A bad config is rejected before the transfer starts, so nothing is read or
written.

### Register map

AXI4-Lite, 32-bit, offsets in bytes.

| Offset | Name | Description |
|--------|------|-------------|
| 0x00 | `CTRL` | Bit 0: START. Self-clearing. Ignored while busy. |
| 0x04 | `STATUS` | Bit 0 busy, 1 done, 2 read error, 3 write error, 4 config error |
| 0x08 | `SRC_ADDR` | Source byte address, multiple of 8 |
| 0x0C | `DST_ADDR` | Destination byte address, multiple of 8 |
| 0x10 | `LEN` | Length in bytes, non-zero multiple of 8 |
| 0x14 | `IRQ_EN` | Bit 0 done, bit 1 error |
| 0x18 | `IRQ_STATUS` | Bit 0 done, bit 1 error. Write 1 to clear. |

`SRC_ADDR`, `DST_ADDR`, `LEN` and `CTRL` cannot be changed while `STATUS.busy`
is set.

Typical use:

```
write SRC_ADDR, DST_ADDR, LEN
write IRQ_EN = 0x3
write CTRL = 1
... wait for irq ...
read  IRQ_STATUS, check for errors
write IRQ_STATUS = 0x3
```

### The DDR part

There is no real DDR PHY or controller in this project. The write master is a
normal AXI4 master, which is what a DDR controller IP presents to the rest of
the chip. For simulation, `tb/axi4_mem_model.sv` is a behavioral memory with DDR
style timing:

- 4 banks, 1KB rows
- open-page policy: a row hit costs CL, a miss costs tRP + tRCD + CL, and the
  first access to a closed bank costs tRCD + CL
- periodic refresh that blocks the interface for tRFC cycles

This makes the DMA see variable latency and stalls from the destination, which
exercises the FIFO and the write engine. The model is simulation only and is
not synthesizable. The source in the testbench is the same model with a flat
2-cycle latency, standing in for an SRAM.

### Files

```
rtl/
  dma_top.sv         top level, wires everything together
  dma_regs.sv        AXI4-Lite registers and interrupt logic
  dma_rd_engine.sv   AXI4 read master
  dma_wr_engine.sv   AXI4 write master
  async_fifo.sv      Gray-code async FIFO
  cdc_pulse.sv       pulse synchronizer
  dma_pkg.sv         burst-length helper (4KB and max-burst limits)
  files.txt          file list used by DC
tb/
  tb_dma.sv          quick directed testbench
  tb_rand.sv         randomized testbench with protocol checker and scoreboard
  axi4_mem_model.sv  AXI4 memory model: optional DDR timing, random stalls, error injection
synth/
  env.sh, env.csh    lab server environment (same as RAPTOR-SoC)
  dc.tcl             Design Compiler script
  constraints.tcl    two-clock constraints
```

## Limits

- Data width is fixed at 64 bits.
- Addresses and lengths must be multiples of 8 bytes.
- The write engine does one burst at a time: AW, then W, then wait for B. It
  does not overlap bursts, which caps throughput.
- One transfer at a time. There is no descriptor list or chaining.
- Read data errors (`RRESP`) are recorded, but the transfer still runs to the
  end instead of stopping early.

## Simulation

Needs Verilator 5.

```
make sim       # quick directed test (tb_dma.sv)
make regress   # randomized test, 5 FIFO depths x 8 seeds
make cov       # line coverage from randomized runs
make lint      # Verilator lint with -Wall
make wave      # open tb_dma.vcd in gtkwave
```

Override `FIFO_AWS`, `SEEDS` and `ITER` on the command line, for example
`make regress SEEDS="1 2 3" ITER=500`. A failing run leaves its log in
`build/log_aw<depth>_s<seed>.txt`.

### Directed test (`tb/tb_dma.sv`)

Five short tests: a 1KB copy with interrupt and write-1-to-clear, a copy that
crosses a 4KB boundary on both sides, a bad length, a masked interrupt, and a
32KB copy into the DDR model (4875 cycles on the 100 MHz side, about 6.7 bytes
per cycle, with 243 row hits, 56 misses and 18 refreshes).

### Randomized test (`tb/tb_rand.sv`)

Each run does the following.

- **D1, bad configs:** zero length, unaligned source, unaligned destination and a
  length that is not a multiple of 8. Each must raise the error interrupt with no
  bus traffic.
- **D2, lock while busy:** `SRC`, `DST` and `LEN` writes and a second START are
  ignored during a transfer. `STATUS` shows busy and not done while it runs.
- **D3, masked interrupt:** the pin stays low while `IRQ_STATUS` still sets.
- **D4, reset mid-transfer:** 10 resets at random points. After each, every
  register must read 0, `irq` must be low, and a new transfer must work.
- **R, random transfers (200 per run):** random length (8 bytes to about 11KB),
  source and destination addresses (often right next to a 4KB boundary), read
  and write clock ratios from about 1:6 to 5:1, and 0 to 92% random stalls on
  every channel of both memories. About one in eight transfers has an AXI error
  response injected on the read or the write side.
- **B, back-to-back:** 30 transfers started as soon as the last one finishes.

The memory models stall `ARREADY`, `AWREADY`, `RVALID`, `WREADY` and `BVALID`
randomly, and keep `VALID` high until `READY` as AXI requires.

Checks that run on every transfer:

- AXI protocol: `VALID` and payload stay stable until `READY`; bursts are at most
  16 beats, 8-byte aligned and never cross 4KB; addresses are contiguous across
  bursts; `WLAST` is on the right beat; `WSTRB` is all ones; one `B` response per
  burst.
- Byte counts: bytes read, bytes in `AW` bursts, and bytes written all equal `LEN`.
- FIFO: it never overflows or underflows.
- Registers: after the interrupt, `STATUS` shows not busy and done, the right
  read or write error bit, and `IRQ_STATUS` matches; write-1-to-clear drops `irq`.
- Data: every destination word equals its source word, no word outside the
  destination changed, and the source was not modified.

### Results

`make regress` passes for FIFO depths 4, 8, 16, 32 and 64 entries, with seeds 1
to 8 for each (40 runs, about 200 transfers each). The DUT RTL did not need any
changes. The only bugs found during this work were in the memory models, which
were fixed.

To check that the testbench can fail, 18 bugs were injected one at a time into a
copy of the RTL (no 4KB split, burst cap of 17, `WLAST` off by one, FIFO full or
empty flag broken, no register lock, error bits dropped, write-1-to-clear
inverted, interrupt enable ignored, bad configs accepted, wrong read address, B
response skipped, `RREADY` ignoring the FIFO, registers not reset, start pulse
lost, `done` not cleared on start). All 18 were caught.

`make cov` shows every RTL line reached except `default:` branches that cannot
happen and reads of `CTRL` and unmapped register addresses.

### Not tested

- Formal proofs of the FIFO or the engines. Formal tools are not installed here.
- Real CDC checking. Zero-delay simulation cannot show metastability or a
  synchronizer failing. That needs a CDC tool or a gate-level run with timing.
- A real DDR controller, or AXI interconnect behavior such as out-of-order
  responses and multiple outstanding bursts (the DMA never has more than one).
- Resetting only one of the two clock domains. Both resets must be applied
  together.

## Synthesis (Design Compiler)

The flow is the same as RAPTOR-SoC. On the lab server:

```
source synth/env.sh        # or: source synth/env.csh
make dc-elab               # analyze, elaborate, link, check_design
make dc                    # full compile_ultra
make dc-report             # rewrite reports from the saved mapped design
make dc-collect RUN=run2   # copy reports to synth/run2 so they can be committed
```

`make dc` runs `dc_shell` inside `synth/build/`, so `command.log`,
`default.svf` and `filenames.log` stay out of the repository root.

`env.sh` sets `DC_HOME`, `PDK_DIR`, the license server and `TARGET_LIBRARY`
(FreePDK45 `gscl45nm.db`). Variables you can override before running:

| Variable | Default | Meaning |
|----------|---------|---------|
| `DC_RD_PERIOD` | 10.0 | `clk_rd` period in ns |
| `DC_WR_PERIOD` | 8.0 | `clk_wr` period in ns |
| `DC_HOLD_UNCERTAINTY` | 0.1 | hold uncertainty on both clocks, in ns |
| `DC_FIX_HOLD` | 0 | set to 1 to let `compile_ultra` insert hold delay cells |
| `DC_OUT_DIR` | `synth/build` | where results and reports go |
| `DC_OUTPUT_LOAD` | 0.01 | load on every output port |

Results land in `synth/build/` (`results/dma_top.v`, `.ddc`, `.sdc`, and
`reports/area.rpt`, `timing.rpt`, `qor.rpt` and others).

### Constraints

`synth/constraints.tcl` has one clock per domain, 5% setup uncertainty, 20% input
and output delays, and a list of every clock crossing. Ports are assigned to a
clock by name, so if you rename a write-side port, update the lists at the top
of that file.

The clocks are not set with `set_clock_groups -asynchronous`. That command acts
as a false path, and a false path overrides `set_max_delay`. Each crossing is
listed instead:

| Crossing | Constraint |
|----------|------------|
| FIFO Gray-code pointers, both directions | `set_max_delay` of the shorter clock period, hold false path |
| START and DONE toggles | same |
| Write error flag to `clk_rd` | same |
| FIFO storage to the write side | false path (the pointers keep the data stable) |
| `SRC_ADDR`, `DST_ADDR`, `LEN` to the write side | false path (locked while busy) |

A crossing that is not in the list is timed as if the clocks were related. If
a report shows a path from one clock to the other, a crossing was missed. The
script prints `CDC crossing constrained: <name>` for each match and
`WARNING: CDC constraint matched no cells` if a name pattern finds nothing.

### Run 1 results (`synth/run1/`)

First run, with the old constraints (10 ns and 8 ns, asynchronous clock groups).

| Item | Result |
|------|--------|
| Setup, `clk_rd` | met, 2.83 ns slack |
| Setup, `clk_wr` | met, 4.60 ns slack |
| Area | 40,851 um2, 10,841 cells, 2,465 flip-flops, no latches |
| Largest block | `async_fifo`, 78.7% of the area |
| Hold | 2,316 violations on `clk_rd`, 134 on `clk_wr`, worst -0.77 ns |
| Max capacitance | 4,509 nets, limit shown as 0 on flip-flop outputs |

Most of the area is the 32 x 64 FIFO storage, which is built from flip-flops
because there is no SRAM macro.

The hold violations are pre-layout effects. The clock is ideal, the library hold
time of the flip-flop is 0.40 ns, and run 1 used 0.5 ns of hold uncertainty. The
worst path is a FIFO storage flip-flop that feeds its own input through a hold
mux. Hold is normally fixed after clock tree synthesis. Run 2 lowers the hold
uncertainty to 0.1 ns. Set `DC_FIX_HOLD=1` to see what DC does about it, at the
cost of more area.

The max-capacitance violations list a required capacitance of exactly 0 on
flip-flop outputs. This looks like a property of the library and not a design
fault. It has not been checked in the library file.

The critical setup path is `m_rvalid` to the write enable of all 2,048 FIFO
flip-flops. The flip-flop setup time in this library is 2.9 ns. Try
`DC_RD_PERIOD=7 DC_WR_PERIOD=6 make dc` to find the limit.

### FIFO storage uses gated clocks

In runs 1 to 4, each FIFO storage flip-flop held its value through a feedback
mux. That path is 0.14 ns, and the library flip-flop needs 0.40 ns of hold time,
so all 2,048 storage flip-flops failed hold. Fixing it with delay cells made the
design 2.5 times bigger (run 4: 101,314 um2).

Now each FIFO entry has its own gated clock: a latch that is open while the
clock is low, and an AND gate (`async_fifo.sv`, block `g_entry`). An entry loads
`wdata` directly, only when it is written. There is no feedback mux, and the data
comes from an input pin, so hold is no longer a problem for the storage.

- The design now contains 32 latches (one per entry).
- Simulation passes: the directed test and all 40 randomized runs, and two
  injected clock-gate bugs are caught.
- Not run in Design Compiler yet. The library must have a latch cell, and the
  32 latch enables may show a few hold violations of their own.
- Gated clocks need care in clock tree synthesis. A library clock-gating cell
  would be better than this latch and AND gate in a real flow.

Things to know:

- Run 2 and run 4 were made before the gated-clock FIFO.
- Lint warnings in the reports are expected: unused address bits, `WSTRB` tied
  to 1, and the unused `rlast` input.

## Ideas for later

- Overlap AW, W and B so the write side can keep several bursts in flight.
- Scatter-gather descriptors with an interrupt per descriptor.
- A reverse direction (DDR to SRAM) or a second channel.
- Formal checks on the FIFO and engines, and a CDC tool run.
