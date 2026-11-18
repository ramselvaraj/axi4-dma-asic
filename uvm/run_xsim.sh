#!/usr/bin/env bash
# Local run with Vivado xsim (it ships UVM 1.2):  uvm/run_xsim.sh [test] [+NUM_XFERS=n] [seed]
set -euo pipefail
cd "$(dirname "$0")/.."
V=${VIVADO_BIN:-/mnt/windows/vivado_linux/2026.1/Vivado/bin}
TEST=${1:-dma_full_test}; N=${2:-100}; SEED=${3:-1}; AW=${4:-5}
OUT=build/uvm_xsim/${TEST}_aw${AW}_s${SEED}; mkdir -p $OUT; cd $OUT
RTL=$(sed 's#^#../../../#' ../../../rtl/files.txt)
$V/xvlog -sv -L uvm $RTL ../../../tb/axi4_mem_model.sv ../../../uvm/dma_if.sv ../../../uvm/dma_uvm_pkg.sv ../../../uvm/tb_top.sv -i ../../../uvm 2>&1 | tail -30
$V/xelab -L uvm tb_top -s dma_sim -timescale 1ns/1ps -debug off -generic_top FIFO_AW=$AW 2>&1 | tail -20
$V/xsim dma_sim -runall -sv_seed $SEED -testplusarg UVM_TESTNAME=$TEST -testplusarg NUM_XFERS=$N -testplusarg UVM_VERBOSITY=UVM_LOW > run.log 2>&1; grep -E "UVM_(ERROR|FATAL) :|TEST (PASSED|FAILED)|functional coverage|transfers observed|FATAL_ERROR" run.log
