# UVM testbench for the AXI4 DMA

A UVM 1.2 environment for `dma_top` (AXI4-Lite control, AXI4 read master, async FIFO, AXI4 write master).

```
tb_top ── dma_top ── axi4_mem_model (source, clk_rd) / axi4_mem_model (destination "DDR", clk_wr)
  │
  └─ uvm_test_top (dma_*_test)
       └─ dma_env
            ├─ dma_agent: sequencer, dma_driver (AXI4-Lite master), dma_reg_monitor
            ├─ dma_rd_monitor   AR/R protocol checks + burst records   (clk_rd)
            ├─ dma_wr_monitor   AW/W/B protocol checks + burst records (clk_wr)
            ├─ dma_scoreboard   passive: rebuilds each transfer from the register traffic, checks the bursts,
            │                   byte counts, status/IRQ bits and the full memory contents (backdoor)
            └─ dma_coverage     functional covergroup over the finished transfers
```

| File | What |
|---|---|
| `dma_if.sv` | AXI4-Lite interface (clocking blocks), AXI4 read/write monitor interfaces, control/knob interface |
| `dma_uvm_pkg.sv` + `*.svh` | items, driver, monitors, scoreboard, coverage, env, sequences, tests |
| `tb_top.sv` | DUT + memory models + clocks/reset + backdoor + config_db |
| `run_vcs.sh` / `run_xsim.sh` | Synopsys VCS / Vivado xsim runners |
| `uvm_mutate.py` | RTL mutation campaign against this environment (xsim) |

Tests (`+UVM_TESTNAME=`): `dma_smoke_test` (corners + 10 random), `dma_rand_test` (legal random transfers: sizes, 4 KiB-edge
addresses, memory stalls, clock ratios), `dma_cfg_err_test` (rejected configurations incl. the 4 GiB overflow, finding D1),
`dma_err_inj_test` (SLVERR on one read/write beat), `dma_full_test` (all of them). `+NUM_XFERS=n` scales the random sequences.

## Run on Synopsys VCS (step by step)

1. Check the tool: `which vcs && vcs -ID | head -3` (needs `VCS_HOME` set and a license, e.g. `export SNPSLMD_LICENSE_FILE=port@server`).
2. Copy the repo (or just `rtl/`, `tb/axi4_mem_model.sv`, `uvm/`) to the VCS machine. Keep the relative layout.
3. `cd uvm && ./run_vcs.sh dma_smoke_test 10 1` - compiles and runs the smoke test. Expect
   `UVM_ERROR : 0`, `TEST PASSED`, and about "23 transfers observed".
4. `./run_vcs.sh dma_full_test 200 1` - the full regression (a minute or two).
5. Seeds and FIFO depths: `for s in 1 2 3 4 5; do ./run_vcs.sh dma_full_test 200 $s 5; done`, and the last argument
   (`FIFO_AW`) 2..6 as in the Verilator regression.
6. Coverage: `COV=1 ./run_vcs.sh dma_full_test 200 1` then open `build/uvm_vcs/cov_report/dashboard.txt`.
   The functional covergroup percentage is printed in the log (`[COV] functional coverage`).
7. If compile fails, send me `build/uvm_vcs/compile.log` (first 30 lines).

Plain-VCS equivalent of `run_vcs.sh`:

```
vcs -full64 -sverilog -timescale=1ns/1ps -ntb_opts uvm-1.2 -debug_access+all +incdir+uvm \
    $(sed 's#^#./#' rtl/files.txt) tb/axi4_mem_model.sv uvm/dma_if.sv uvm/dma_uvm_pkg.sv uvm/tb_top.sv -top tb_top -o simv
./simv +UVM_TESTNAME=dma_full_test +NUM_XFERS=200 +ntb_random_seed=1
```

## What was verified (and what was not)

Developed and run on **Vivado xsim 2026.1** (UVM 1.2), because VCS is not available on the development machine.
It has **not been compiled with VCS yet**: the code uses only standard SystemVerilog/UVM 1.2 and avoids solver features that
xsim's constraint solver rejects, but expect to possibly fix a small tool-specific warning or two on the first VCS compile.
xsim results are in the "Results" section below.

Design notes: the scoreboard reads the memory models through a backdoor class (`mem_access_base`) set in `config_db`, so
the package has no hierarchical references. Addresses are derived in `post_randomize()` (the xsim solver crashed on
overflow-style address constraints). The overflow cases (`K_SRC_OVERFLOW`/`K_DST_OVERFLOW`) are the regression for D1.

## Results (Vivado xsim 2026.1, UVM 1.2; measured 2026-11-18)

- **Regression:** 5 tests x FIFO_AW 2,3,4,5,6 x 2 seeds = **50/50 runs pass**, `UVM_ERROR : 0`, `UVM_FATAL : 0`.
  One `dma_full_test` run (120 transfers/sequence) verified 194 legal transfers (memory fully compared) and 29 rejected configurations.
- **Functional coverage** (covergroup in `dma_coverage`): 82-97% per run depending on test and size; the full test at 100+ transfers is
  around 92-97%. Not 100%: some cross bins (length x write-stall) need more transfers than these runs use.
- **Mutation check of the environment** (`uvm/uvm_mutate.py`, 65 RTL bugs from `mutation/mutate_dma.py` plus 2 regressions of the
  D1 fix): **63/67 killed** (`uvm/mutation_matrix.md`). The 4 survivors are the same ones already explained for the plain
  testbench (`mutation/README.md`): `fifo_read_when_empty` and `fifo_write_when_full` (redundant guards, the DMA already gates
  with `!rempty`/`!wfull`), `wr_bready_always` (one outstanding burst) and `cdc_pulse_one_ff` (metastability-only).
- The first mutation run killed 53/67; the surviving mutants exposed real checker gaps, which were then closed: register
  readback and reset values, config lock and ignored second START while busy, masked-IRQ operation, reset in the middle of a
  transfer, FIFO overflow/underflow checks, `done` must clear on START (now 63/67).
- The D1 fix is covered twice: `K_SRC_OVERFLOW`/`K_DST_OVERFLOW` items must be rejected with no bus traffic, and removing
  the check from the RTL is killed by the scoreboard (`read burst after a rejected configuration`).

Not covered here: formal proofs (see `../formal`), the gated-clock async FIFO variant's timing, and anything specific to VCS
(not yet run there).
