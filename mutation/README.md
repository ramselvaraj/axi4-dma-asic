# Mutation testing

`mutate_dma.py` injects one RTL bug at a time into a scratch copy of the design and runs the randomized testbench
(`tb/tb_rand.sv`: protocol checker, memory scoreboard, register/IRQ checks, error injection) under two FIFO depths
(`FIFO_AW` = 3 with seeds 1-3, then 2 with seeds 4-5). A mutant is **killed** if the testbench reports a failure, times
out or aborts. The first failing check is recorded, so the result is a bug-catch matrix (`matrix.md`). The unmodified
design must pass first.

```
python3 mutation/mutate_dma.py --jobs 14 --report mutation/matrix.md
```

## Results

**65 mutants, 61 killed** (the earlier manual campaign injected 18). Killed per area:

| Area | Killed / total |
|---|---|
| burst arithmetic (`dma_pkg`) | 4 / 4 |
| read engine | 12 / 12 |
| write engine | 14 / 15 |
| register block / interrupts | 22 / 22 |
| top-level integration | 2 / 2 |
| CDC pulse synchronizer | 1 / 2 |
| async FIFO | 6 / 8 |

Checks that did the catching (see `matrix.md`): AR/AW 4 KiB and 16-beat rules, contiguity of burst addresses, `WLAST`,
`WSTRB`, AR/AW/W hold-until-ready, FIFO overflow/underflow, byte accounting, scoreboard data compare (including "no word outside
the destination changed"), D2 register lock-while-busy, D3 interrupt masking, error-bit and IRQ_STATUS checks, SRC/DST/LEN reset values.

### A testbench gap this found (and fixed)

`regs_bresp_slverr` and `regs_rresp_slverr` (the register block answering SLVERR to every access) **survived** at first:
the testbench never looked at the AXI4-Lite response codes. A small passive checker was added to `tb_rand.sv` (it fails
on any non-OKAY `BRESP`/`RRESP`); the unmodified design still passes and both mutants are now killed.

### Survivors (4), all explained

| Mutant | Why it survives |
|---|---|
| `wr_bready_always` | `BREADY` high before a response is pending is harmless here: the DMA never has more than one outstanding burst, so no response can arrive early. Equivalent in this system |
| `fifo_read_when_empty`, `fifo_write_when_full` | The FIFO's own `~empty`/`~full` guards are redundant in the DMA: `wvalid` already requires `!rempty` and `rready` already requires `!wfull`. They matter for a standalone FIFO, which the `formal/` work does not cover for this gated-clock variant |
| `cdc_pulse_one_ff` | Taps the first synchronizer flop instead of the second. The difference is metastability, which a zero-delay simulation cannot show (the README's "Not tested" already says CDC needs a CDC tool or timing-annotated simulation); formal methods do not model it either |
