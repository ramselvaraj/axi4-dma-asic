#!/usr/bin/env python3
"""Mutation testing of the AXI4 DMA against the randomized testbench (tb_rand.sv).

Each mutant is a one-line RTL bug in a scratch copy. It is built with the random testbench and run under two FIFO depths
and several seeds; it is KILLED if tb_rand reports a failure, times out or aborts. The first failing check is recorded,
which gives the bug-catch matrix (mutant -> the check that caught it). The unmodified RTL must pass first.

  mutate_dma.py [--jobs 14] [--iter 80] [--only NAME] [--report matrix.md]
"""
import argparse, collections, os, re, shutil, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
RTL = [l.strip() for l in open(f"{ROOT}/rtl/files.txt") if l.strip()]
TB = ["tb/axi4_mem_model.sv", "tb/tb_rand.sv"]
CONFIGS = [("aw3", 3, (1, 2, 3)), ("aw2", 2, (4, 5))]

# (name, area, file, old, new)      area: the part of the design the bug lives in
M = [
 # ---- address / burst generation (dma_pkg, dma_rd_engine, dma_wr_engine)
 ("no_4k_clamp",            "burst",  "dma_pkg.sv",       "if (page_beats < m) m = page_beats;", ""),
 ("max_beats_17",           "burst",  "dma_pkg.sv",       "localparam int MAX_BEATS = 16;", "localparam int MAX_BEATS = 17;"),
 ("no_remaining_clamp",     "burst",  "dma_pkg.sv",       "if (rem_beats  < m) m = rem_beats;", ""),
 ("page_calc_off_by_8",     "burst",  "dma_pkg.sv",       "to_4k      = 32'd4096 - {20'd0, addr[11:0]};", "to_4k      = 32'd4104 - {20'd0, addr[11:0]};"),
 ("rd_arlen_off_by_one",    "read",   "dma_rd_engine.sv", "arlen   <= 8'(beats) - 8'd1;", "arlen   <= 8'(beats);"),
 ("rd_cur_step_fixed",      "read",   "dma_rd_engine.sv", "cur     <= cur + beat_bytes;", "cur     <= cur + 32'd8;"),
 ("rd_rem_step_fixed",      "read",   "dma_rd_engine.sv", "rem     <= rem - beat_bytes;", "rem     <= rem - 32'd8;"),
 ("rd_busy_clears_early",   "read",   "dma_rd_engine.sv", "if (rem == beat_bytes) ar_busy <= 1'b0;", "if (rem <= beat_bytes + 32'd8) ar_busy <= 1'b0;"),
 ("rd_araddr_plus8",        "read",   "dma_rd_engine.sv", "araddr  <= cur;", "araddr  <= cur + 32'd8;"),
 ("rd_arvalid_drops",       "read",   "dma_rd_engine.sv", "if (arvalid && arready) arvalid <= 1'b0;", "if (arvalid) arvalid <= 1'b0;"),
 ("rd_err_never_set",       "read",   "dma_rd_engine.sv", "if (rvalid && rready && rresp != 2'b00) err <= 1'b1;", "if (1'b0) err <= 1'b1;"),
 ("rd_err_only_decerr",     "read",   "dma_rd_engine.sv", "rresp != 2'b00) err <= 1'b1;", "rresp == 2'b11) err <= 1'b1;"),
 ("rd_err_not_cleared",     "read",   "dma_rd_engine.sv", "ar_busy <= 1'b1; err <= 1'b0;", "ar_busy <= 1'b1;"),
 ("rd_rready_ignores_fifo", "read",   "dma_rd_engine.sv", "assign rready     = !fifo_wfull;", "assign rready     = 1'b1;"),
 ("rd_winc_ignores_ready",  "read",   "dma_rd_engine.sv", "assign fifo_winc  = rvalid && rready;", "assign fifo_winc  = rvalid;"),
 ("rd_start_ignored_busy",  "read",   "dma_rd_engine.sv", "end else if (ar_busy && !arvalid) begin", "end else if (ar_busy) begin"),
 ("wr_awlen_off_by_one",    "write",  "dma_wr_engine.sv", "awlen   <= 8'(beats) - 8'd1;", "awlen   <= 8'(beats);"),
 ("wr_awaddr_plus8",        "write",  "dma_wr_engine.sv", "awaddr  <= cur;", "awaddr  <= cur + 32'd8;"),
 ("wr_cur_step_fixed",      "write",  "dma_wr_engine.sv", "cur     <= cur + beat_bytes;", "cur     <= cur + 32'd8;"),
 ("wr_rem_step_fixed",      "write",  "dma_wr_engine.sv", "rem     <= rem - beat_bytes;", "rem     <= rem - 32'd8;"),
 ("wr_wlast_early",         "write",  "dma_wr_engine.sv", "assign wlast     = (cnt == 5'd1);", "assign wlast     = (cnt == 5'd2);"),
 ("wr_wstrb_partial",       "write",  "dma_wr_engine.sv", "assign wstrb     = '1;", "assign wstrb     = {{(DW/8-1){1'b1}}, 1'b0};"),
 ("wr_bready_always",       "write",  "dma_wr_engine.sv", "assign bready    = (st == S_RESP);", "assign bready    = 1'b1;"),
 ("wr_b_response_skipped",  "write",  "dma_wr_engine.sv", "S_RESP: if (bvalid) begin", "S_RESP: begin"),
 ("wr_err_never_set",       "write",  "dma_wr_engine.sv", "if (bresp != 2'b00) err <= 1'b1;", "if (1'b0) err <= 1'b1;"),
 ("wr_wvalid_ignores_empty","write",  "dma_wr_engine.sv", "assign wvalid    = (st == S_DATA) && !fifo_rempty;", "assign wvalid    = (st == S_DATA);"),
 ("wr_rinc_ignores_ready",  "write",  "dma_wr_engine.sv", "assign fifo_rinc = wvalid && wready;", "assign fifo_rinc = wvalid;"),
 ("wr_cnt_load_minus1",     "write",  "dma_wr_engine.sv", "cnt     <= beats;", "cnt     <= beats - 5'd1;"),
 ("wr_done_one_burst_early","write",  "dma_wr_engine.sv", "st <= (rem == 32'd0) ? S_DONE : S_ISSUE;", "st <= (rem <= 32'd8) ? S_DONE : S_ISSUE;"),
 ("wr_aw_not_held",         "write",  "dma_wr_engine.sv", "S_AW: if (awready) begin awvalid <= 1'b0; st <= S_DATA; end", "S_AW: begin awvalid <= 1'b0; st <= S_DATA; end"),
 ("wr_err_not_cleared",     "write",  "dma_wr_engine.sv", "cur <= dst; rem <= len; err <= 1'b0; st <= S_ISSUE;", "cur <= dst; rem <= len; st <= S_ISSUE;"),
 # ---- register block and interrupts
 ("regs_src_not_locked",    "regs",   "dma_regs.sv",      "3'd2: if (!busy) src_addr <= s_wdata;", "3'd2: src_addr <= s_wdata;"),
 ("regs_dst_not_locked",    "regs",   "dma_regs.sv",      "3'd3: if (!busy) dst_addr <= s_wdata;", "3'd3: dst_addr <= s_wdata;"),
 ("regs_len_not_locked",    "regs",   "dma_regs.sv",      "3'd4: if (!busy) len      <= s_wdata;", "3'd4: len      <= s_wdata;"),
 ("regs_start_while_busy",  "regs",   "dma_regs.sv",      "3'd0: if (s_wdata[0] && !busy) begin", "3'd0: if (s_wdata[0]) begin"),
 ("regs_zero_len_ok",       "regs",   "dma_regs.sv",      "wire cfg_bad = (len == 32'd0) ||", "wire cfg_bad = 1'b0 ||"),
 ("regs_len_align_ok",      "regs",   "dma_regs.sv",      "(len[2:0] != 3'd0) ||", "1'b0 ||"),
 ("regs_src_align_ok",      "regs",   "dma_regs.sv",      "(src_addr[2:0] != 3'd0) ||", "1'b0 ||"),
 ("regs_dst_align_ok",      "regs",   "dma_regs.sv",      "(dst_addr[2:0] != 3'd0);", "1'b0;"),
 ("regs_w1c_inverted",      "regs",   "dma_regs.sv",      "irq_status <= irq_status & ~s_wdata[1:0];", "irq_status <= irq_status & s_wdata[1:0];"),
 ("regs_irq_en_ignored",    "regs",   "dma_regs.sv",      "assign irq       = |(irq_status & irq_en);", "assign irq       = |irq_status;"),
 ("regs_done_not_cleared",  "regs",   "dma_regs.sv",      "start <= 1'b1; busy <= 1'b1; done <= 1'b0;", "start <= 1'b1; busy <= 1'b1;"),
 ("regs_err_bits_dropped",  "regs",   "dma_regs.sv",      "rd_err_q <= rd_err; wr_err_q <= wr_err;", "rd_err_q <= 1'b0; wr_err_q <= 1'b0;"),
 ("regs_err_irq_missing",   "regs",   "dma_regs.sv",      "if (rd_err || wr_err) irq_status[1] <= 1'b1;", ""),
 ("regs_cfg_err_no_irq",    "regs",   "dma_regs.sv",      "cfg_err <= 1'b1; irq_status[1] <= 1'b1;", "cfg_err <= 1'b1;"),
 ("regs_busy_stuck",        "regs",   "dma_regs.sv",      "busy <= 1'b0; done <= 1'b1;", "done <= 1'b1;"),
 ("regs_start_never_fires", "regs",   "dma_regs.sv",      "start <= 1'b1; busy <= 1'b1; done <= 1'b0;", "busy <= 1'b1; done <= 1'b0;"),
 ("regs_status_bits_swapped","regs",  "dma_regs.sv",      "{27'd0, cfg_err, wr_err_q, rd_err_q, done, busy}", "{27'd0, cfg_err, wr_err_q, rd_err_q, busy, done}"),
 ("regs_done_irq_missing",  "regs",   "dma_regs.sv",      "irq_status[0] <= 1'b1;\n        if", "if"),
 ("regs_src_readback_dst",  "regs",   "dma_regs.sv",      "3'd2: s_rdata <= src_addr;", "3'd2: s_rdata <= dst_addr;"),
 ("regs_bresp_slverr",      "regs",   "dma_regs.sv",      "assign s_bresp   = 2'b00;", "assign s_bresp   = 2'b10;"),
 ("regs_rresp_slverr",      "regs",   "dma_regs.sv",      "assign s_rresp   = 2'b00;", "assign s_rresp   = 2'b10;"),
 ("regs_reset_missing",     "regs",   "dma_regs.sv",      "src_addr <= '0; dst_addr <= '0; len <= '0;\n      irq_en <= '0; irq_status <= '0;", "irq_en <= '0; irq_status <= '0;"),
 # ---- integration and CDC
 ("top_wr_err_dropped",     "top",    "dma_top.sv",       ".wr_err(wr_err_s2)", ".wr_err(1'b0)"),
 ("top_done_never",         "top",    "dma_top.sv",       "done_rd_d <= done_rd;", "done_rd_d <= 1'b0;"),
 ("cdc_pulse_one_ff",       "cdc",    "cdc_pulse.sv",     "assign dst_pulse = sync[2] ^ sync[1];", "assign dst_pulse = sync[1] ^ sync[0];"),
 ("cdc_pulse_no_toggle",    "cdc",    "cdc_pulse.sv",     "else if (src_pulse) tgl <= ~tgl;", "else if (src_pulse) tgl <= 1'b1;"),
 # ---- async FIFO
 ("fifo_full_alias_empty",  "fifo",   "async_fifo.sv",    "wfull <= (wgray_n == {~wq2_rgray[AW:AW-1], wq2_rgray[AW-2:0]});", "wfull <= (wgray_n == wq2_rgray);"),
 ("fifo_never_empty",       "fifo",   "async_fifo.sv",    "rempty <= (rgray_n == rq2_wgray);", "rempty <= 1'b0;"),
 ("fifo_never_full",        "fifo",   "async_fifo.sv",    "wfull <= (wgray_n == {~wq2_rgray[AW:AW-1], wq2_rgray[AW-2:0]});", "wfull <= 1'b0;"),
 ("fifo_binary_wptr_crosses","fifo",  "async_fifo.sv",    "begin wbin <= wbin_n; wgray <= wgray_n; end", "begin wbin <= wbin_n; wgray <= wbin_n; end"),
 ("fifo_write_slot_off",    "fifo",   "async_fifo.sv",    "assign en = we && (wbin[AW-1:0] == IDX);", "assign en = we && ((wbin[AW-1:0] + 1'b1) == IDX);"),
 ("fifo_read_index_gray",   "fifo",   "async_fifo.sv",    "assign rdata = mem_q[rbin[AW-1:0]];", "assign rdata = mem_q[rgray[AW-1:0]];"),
 ("fifo_read_when_empty",   "fifo",   "async_fifo.sv",    "wire [AW:0] rbin_n  = rbin + {{AW{1'b0}}, (rinc & ~rempty)};", "wire [AW:0] rbin_n  = rbin + {{AW{1'b0}}, rinc};"),
 ("fifo_write_when_full",   "fifo",   "async_fifo.sv",    "wire [AW:0] wbin_n  = wbin + {{AW{1'b0}}, (winc & ~wfull)};", "wire [AW:0] wbin_n  = wbin + {{AW{1'b0}}, winc};"),
]

def build_run(work, area_cfg, seeds):
    name, aw = area_cfg
    mdir = f"{work}/{name}"
    r = subprocess.run(["verilator", "--binary", "--timing", "--assert", "-Wno-fatal", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC", "-Wno-WIDTHCONCAT",
                        "--top-module", "tb_rand", f"-GFIFO_AW={aw}", f"-GITER={ITER}", *[f"{work}/{f}" for f in RTL + TB], "--Mdir", mdir],
                       capture_output=True, text=True)
    exe = f"{mdir}/Vtb_rand"
    if not os.path.exists(exe): return "BUILD-FAIL", r.stderr[-200:]
    for s in seeds:
        p = subprocess.run([exe, f"+verilator+seed+{s}"], capture_output=True, text=True, timeout=600)
        out = p.stdout + p.stderr
        m = re.search(r"FAIL: (.*)", out)
        if p.returncode != 0 or m:
            if m: msg = re.sub(r"[0-9a-fx]{4,}|\d+", "N", m.group(1)).strip()      # normalise numbers/addresses
            elif "TIMEOUT" in out: msg = "GLOBAL TIMEOUT"
            else: msg = "abort/assertion"
            return "KILLED", f"{name} seed {s}: {msg}"
    return "PASS", ""

def run_mutant(m):
    name, area, f, old, new = m
    work = tempfile.mkdtemp(prefix=f"dm_{name}_")
    try:
        for x in RTL + TB:
            os.makedirs(os.path.dirname(f"{work}/{x}"), exist_ok=True); shutil.copy(f"{ROOT}/{x}", f"{work}/{x}")
        if f:
            p = f"{work}/rtl/{f}"; s = open(p).read()
            if s.count(old) != 1: return name, area, "BAD-PATTERN", f"pattern occurs {s.count(old)}x"
            open(p, "w").write(s.replace(old, new))
        for cname, aw, seeds in CONFIGS:
            st, why = build_run(work, (cname, aw), seeds)
            if st != "PASS": return name, area, st, why
        return name, area, "SURVIVED", ""
    finally:
        shutil.rmtree(work, ignore_errors=True)

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--jobs", type=int, default=14); ap.add_argument("--iter", type=int, default=80)
    ap.add_argument("--only"); ap.add_argument("--report"); a = ap.parse_args(); ITER = a.iter
    base = run_mutant(("baseline", "-", None, "", ""))
    print(f"baseline (unmodified RTL): {base[2]} {base[3]}", flush=True)
    if base[2] != "SURVIVED": sys.exit("baseline must pass first")
    muts = [m for m in M if not a.only or a.only in m[0]]; t0 = time.time(); res = []
    with ThreadPoolExecutor(a.jobs) as ex:
        for r in ex.map(run_mutant, muts): res.append(r); print(f"{r[0]:26s} {r[1]:7s} {r[2]:9s} {r[3]}", flush=True)
    by = collections.Counter(); bad = collections.Counter()
    for n, area, st, why in res:
        by[area] += 1
        if st == "KILLED": bad[area] += 1
    print("== per area (killed/total):", {k: f"{bad[k]}/{by[k]}" for k in by})
    print(f"== killed {sum(r[2]=='KILLED' for r in res)}/{len(res)} in {time.time()-t0:.0f}s; survivors: {[r[0] for r in res if r[2]=='SURVIVED'] or 'none'}")
    if a.report:
        with open(a.report, "w") as f:
            f.write("| Area | Mutant | Result | First check that fired (config, seed: message) |\n|---|---|---|---|\n")
            for n, area, st, why in res: f.write(f"| {area} | `{n}` | {st} | {why or '-'} |\n")
