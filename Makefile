VERILATOR ?= verilator
DC_SHELL  ?= dc_shell
RTL := $(shell cat rtl/files.txt)
TB  := tb/axi4_mem_model.sv tb/tb_dma.sv

.DEFAULT_GOAL := sim
.PHONY: sim lint regress cov dc dc-elab dc-report wave clean

# Simulation (Verilator)
sim: obj_dir/Vtb_dma
	./obj_dir/Vtb_dma

obj_dir/Vtb_dma: $(RTL) $(TB)
	$(VERILATOR) --binary --timing --trace -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
		--top-module tb_dma $(RTL) $(TB)

# Randomized regression: every FIFO depth in FIFO_AWS, every seed in SEEDS.
FIFO_AWS ?= 2 3 4 5 6
SEEDS    ?= 1 2 3 4 5 6 7 8
ITER     ?= 200
RAND_TB  := tb/axi4_mem_model.sv tb/tb_rand.sv
RAND_FLAGS := --binary --timing --assert -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-WIDTHCONCAT

build/rand_aw%/Vtb_rand: $(RTL) $(RAND_TB)
	mkdir -p build/rand_aw$*
	$(VERILATOR) $(RAND_FLAGS) --top-module tb_rand -GFIFO_AW=$* -GITER=$(ITER) 		$(RTL) $(RAND_TB) --Mdir build/rand_aw$*

regress: $(foreach a,$(FIFO_AWS),build/rand_aw$(a)/Vtb_rand)
	@fail=0; \
	for a in $(FIFO_AWS); do for s in $(SEEDS); do \
		if ./build/rand_aw$$a/Vtb_rand +verilator+seed+$$s > build/log_aw$${a}_s$$s.txt 2>&1; then \
			echo "FIFO_AW=$$a seed=$$s  PASS"; \
		else echo "FIFO_AW=$$a seed=$$s  FAIL (see build/log_aw$${a}_s$$s.txt)"; fail=1; fi; \
	done; done; \
	[ $$fail -eq 0 ] && echo "ALL REGRESSION RUNS PASSED" || (echo "SOME RUNS FAILED"; exit 1)

# Line/toggle coverage from one randomized run (needs verilator_coverage).
cov:
	mkdir -p build/cov
	$(VERILATOR) $(RAND_FLAGS) --coverage --top-module tb_rand -GFIFO_AW=3 -GITER=$(ITER) \
		$(RTL) $(RAND_TB) --Mdir build/cov
	cd build/cov && for s in 1 2 3; do ./Vtb_rand +verilator+seed+$$s > /dev/null && mv coverage.dat cov_$$s.dat; done
	verilator_coverage --annotate build/cov/annotate --annotate-min 1 build/cov/cov_*.dat

wave: sim
	gtkwave tb_dma.vcd

lint:
	$(VERILATOR) --lint-only -Wall -DSYNTHESIS --top-module dma_top \
		-Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-SYNCASYNCNET $(RTL)

# Design Compiler. Run "source synth/env.sh" first (csh: synth/env.csh).
dc:
	$(DC_SHELL) -f synth/dc.tcl

dc-elab:
	DC_ELAB_ONLY=1 $(DC_SHELL) -f synth/dc.tcl

dc-report:
	DC_REPORT_ONLY=1 $(DC_SHELL) -f synth/dc.tcl

clean:
	rm -rf obj_dir build tb_dma.vcd synth/build
