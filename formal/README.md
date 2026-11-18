# Formal verification (SymbiYosys)

Properties are attached with `bind` (the RTL is not modified) and checked with SymbiYosys + yosys-slang
(OSS CAD Suite 2026-11-18; solvers: yices for unbounded proof, boolector for bounded checks and cover).

```
export PATH=$HOME/builds/oss-cad-suite/bin:$PATH
sby -f dma_rd_engine.sby bmc|prove|cover|wrap
sby -f dma_wr_engine.sby bmc|prove|cover
python3 mutants.py          # formal mutation check on the read engine
```

Environment contract (assumed, and what `dma_regs` / the AXI slave guarantee): `start` only while idle; SRC/DST/LEN
8-byte aligned and LEN non-zero (everything else is rejected by `cfg_bad`); the async FIFO never retracts an offered word.

## Results

| Design | Task | Result |
|---|---|---|
| `dma_rd_engine` | `prove` | **unbounded proof (k-induction)**: AR bursts never cross 4 KiB; 1..16 beats; 8-byte aligned addresses; `cur`/`rem` stay 8-byte granular; `ar_busy` implies work remains |
| `dma_rd_engine` | `bmc` (depth 30) | pass, adds byte accounting: issued + remaining == LEN at all times, and nothing left over when issuing stops |
| `dma_rd_engine` | `cover` | 4/4 reached (burst issued, full 16-beat burst, burst shortened by the 4 KiB edge, transfer finishes issuing) |
| `dma_wr_engine` | `prove` | **unbounded proof (k-induction)**: AW 4 KiB rule, 1..16 beats, alignment, FSM encoding, `awvalid == (st == S_AW)`, `WLAST` exactly on the final beat, B/W only accepted in their states, `done` only from idle |
| `dma_wr_engine` | `bmc` (depth 30) | pass, adds: AW/W held until accepted, awlen+1 W beats per burst, byte accounting, `rem == 0` before done |
| `dma_wr_engine` | `cover` | 4/4 reached |
| `dma_rd_engine` | `wrap` | **fails, by design: finding D1 below** |

The 32-bit accounting properties do not converge in k-induction or PDR, so they are bounded (BMC) checks only; the
shape properties above are unbounded.

### Do the properties have teeth?

`mutants.py` injects an RTL bug into the read engine and runs `bmc` and `prove`:

| Mutant | Caught by |
|---|---|
| no 4 KiB page clamp | prove + bmc |
| no max-burst clamp | prove + bmc |
| `arlen` off by one | prove + bmc |
| `rem -= 8` instead of `rem -= beat_bytes` | bmc (accounting) |
| `cur += 8` instead of `cur += beat_bytes` | bmc (accounting) |
| `ar_busy` clears one burst early | bmc (accounting) |

6 / 6 killed. (A first version of the property set missed the accounting mutants; adding the accounting invariant
is what killed them.)

## Finding D1: no check that SRC + LEN (or DST + LEN) stays inside 4 GiB

`cfg_bad` rejects zero length and unaligned values but not address overflow. No single burst can wrap (bursts stop
at 4 KiB pages and 4 GiB is a page boundary), but a transfer that extends past 0xFFFF_FFFF keeps issuing bursts after
the address counter wraps to 0. Solver counterexample: `src = 0xFFFFFFF8`, `len = 0xC0000000`. Confirmed in plain
simulation of the RTL: a 16-byte transfer from `0xFFFFFFF8` issues `AR addr=fffffff8 beats=1` then `AR addr=00000000 beats=1`.
The write engine has the same structure. Impact: a mis-programmed transfer silently reads/writes low memory instead of
being rejected with `cfg_err`. Suggested fix (not applied): add `({1'b0, src_addr} + len > 33'h1_0000_0000) ||
({1'b0, dst_addr} + len > 33'h1_0000_0000)` to `cfg_bad`.

## Not covered

* `async_fifo.sv` in this repo uses gated-clock storage with latches (hold-time workaround); it is not modelled here.
  The Gray-pointer dual-clock FIFO used in RAPTOR-SoC is verified in that repo's `formal/async_fifo`.
* `dma_regs` (AXI4-Lite register block) and `dma_top` integration have no formal properties yet.
* No liveness properties (transfers eventually complete).
