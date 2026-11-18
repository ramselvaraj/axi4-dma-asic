#!/usr/bin/env python3
"""Formal mutation check: inject an RTL bug, run the `bmc` and `prove` tasks, report whether a property fails.
usage: mutants.py <sby-file> <mutant-table.json>   (default: the DMA read engine mutants below)"""
import subprocess, shutil, os, re, sys
MUT = {
 "no_page_clamp":    ("rtl/dma_pkg.sv", "if (page_beats < m) m = page_beats;", ""),
 "no_max_clamp":     ("rtl/dma_pkg.sv", "if (rem_beats  < m) m = rem_beats;\n    if (page_beats < m) m = page_beats;\n    return", "m = page_beats < rem_beats ? page_beats : rem_beats;\n    return"),
 "arlen_off_by_one": ("rtl/dma_rd_engine.sv", "arlen   <= 8'(beats) - 8'd1;", "arlen   <= 8'(beats);"),
 "rem_wrong_sub":    ("rtl/dma_rd_engine.sv", "rem     <= rem - beat_bytes;", "rem     <= rem - 32'd8;"),
 "cur_wrong_add":    ("rtl/dma_rd_engine.sv", "cur     <= cur + beat_bytes;", "cur     <= cur + 32'd8;"),
 "busy_clears_early":("rtl/dma_rd_engine.sv", "if (rem == beat_bytes) ar_busy <= 1'b0;", "if (rem <= beat_bytes + 32'd8) ar_busy <= 1'b0;"),
}
here = os.path.dirname(os.path.abspath(__file__)); root = os.path.dirname(here)
for n, (f, old, new) in MUT.items():
    d = f"/tmp/fm_{n}"; shutil.rmtree(d, ignore_errors=True); os.makedirs(d + "/formal")
    shutil.copytree(root + "/rtl", d + "/rtl")
    for x in os.listdir(here):
        if x.endswith((".sby", ".sv")): shutil.copy(f"{here}/{x}", d + "/formal/")
    p = f"{d}/{f}"; s = open(p).read()
    if s.count(old) != 1: print(f"{n:20s} BAD-PATTERN"); continue
    open(p, "w").write(s.replace(old, new))
    res = []
    for task in ("bmc", "prove"):
        out = subprocess.run(["sby", "-f", "dma_rd_engine.sby", task], cwd=d + "/formal", capture_output=True, text=True).stdout
        res.append(task + ":" + ("FAIL" if "DONE (FAIL" in out else "pass" if "DONE (PASS" in out else "ERR"))
    killed = any("FAIL" in r for r in res)
    print(f"{n:20s} {'KILLED  ' if killed else 'SURVIVED'} {' '.join(res)}")
