#!/usr/bin/env bash
# Synopsys VCS run of the UVM testbench.
#   ./run_vcs.sh [test] [num_xfers] [seed] [fifo_aw]        e.g.  ./run_vcs.sh dma_full_test 200 1 5
#   COV=1 ./run_vcs.sh dma_full_test 200 1                   also collect code coverage (urg report in cov_report/)
# Run from anywhere; everything is built in <repo>/build/uvm_vcs.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(dirname "$HERE")
TEST=${1:-dma_full_test}; N=${2:-100}; SEED=${3:-1}; AW=${4:-5}
OUT=$ROOT/build/uvm_vcs; mkdir -p "$OUT"; cd "$OUT"
RTL=$(sed "s#^#$ROOT/#" "$ROOT/rtl/files.txt")
CM=""; [ "${COV:-0}" = 1 ] && CM="-cm line+cond+fsm+tgl+branch -cm_dir $OUT/cov.vdb"
# compile + elaborate (one step); -ntb_opts uvm-1.2 supplies the UVM library and macros
vcs -full64 -sverilog -timescale=1ns/1ps -ntb_opts uvm-1.2 -debug_access+all \
    +incdir+"$HERE" -pvalue+tb_top.FIFO_AW=$AW $CM \
    $RTL "$ROOT/tb/axi4_mem_model.sv" "$HERE/dma_if.sv" "$HERE/dma_uvm_pkg.sv" "$HERE/tb_top.sv" \
    -top tb_top -o simv -l compile.log
# run
./simv +UVM_TESTNAME="$TEST" +NUM_XFERS="$N" +ntb_random_seed="$SEED" +UVM_VERBOSITY=UVM_LOW $CM -l "run_${TEST}_s${SEED}.log"
grep -E "UVM_(ERROR|FATAL) :|TEST (PASSED|FAILED)|functional coverage|transfers observed" "run_${TEST}_s${SEED}.log" || true
if [ "${COV:-0}" = 1 ]; then urg -dir "$OUT/cov.vdb" -report "$OUT/cov_report" -format text; echo "coverage report: $OUT/cov_report/dashboard.txt"; fi
