// Tests -------------------------------------------------------------------------------------------------------
class dma_base_test extends uvm_test;
  `uvm_component_utils(dma_base_test)
  dma_env env;
  int unsigned num_xfers = 100;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = dma_env::type_id::create("env", this);
    void'($value$plusargs("NUM_XFERS=%d", num_xfers));
    uvm_top.set_timeout(100ms, 0);
  endfunction
  task run_seq(dma_base_seq s);
    s.start(env.agent.sqr);
  endtask
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    body();
    repeat (50) @(posedge env.agent.drv.vif.clk);
    phase.drop_objection(this);
  endtask
  virtual task body(); endtask
  function void report_phase(uvm_phase phase);
    uvm_report_server rs = uvm_report_server::get_server();
    if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0)
      `uvm_info("RESULT", "*** TEST PASSED ***", UVM_NONE)
    else
      `uvm_info("RESULT", "*** TEST FAILED ***", UVM_NONE)
  endfunction
endclass

// Corner cases, then random legal transfers.
class dma_smoke_test extends dma_base_test;
  `uvm_component_utils(dma_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    dma_corner_seq c = dma_corner_seq::type_id::create("c");
    dma_rand_seq   r = dma_rand_seq::type_id::create("r");
    run_seq(c);
    r.n = 10; r.valid_only = 1; r.inj = 0;
    run_seq(r);
  endtask
endclass

// Constrained-random legal transfers: random sizes, 4 KiB-edge addresses, memory stalls, clock ratios.
class dma_rand_test extends dma_base_test;
  `uvm_component_utils(dma_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    dma_rand_seq r = dma_rand_seq::type_id::create("r");
    r.n = num_xfers; r.valid_only = 1; r.inj = 0;
    run_seq(r);
  endtask
endclass

// Rejected configurations mixed with legal transfers (covers finding D1: 4 GiB overflow).
class dma_cfg_err_test extends dma_base_test;
  `uvm_component_utils(dma_cfg_err_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    dma_rand_seq r = dma_rand_seq::type_id::create("r");
    r.n = num_xfers; r.valid_only = 0; r.inj = 0;
    run_seq(r);
  endtask
endclass

// SLVERR injection on one read or write beat per transfer.
class dma_err_inj_test extends dma_base_test;
  `uvm_component_utils(dma_err_inj_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    dma_rand_seq r = dma_rand_seq::type_id::create("r");
    r.n = num_xfers; r.valid_only = 1; r.inj = 1;
    run_seq(r);
  endtask
endclass

// Everything: corners, random legal, rejected configs, error injection.
class dma_full_test extends dma_base_test;
  `uvm_component_utils(dma_full_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    dma_corner_seq c = dma_corner_seq::type_id::create("c");
    dma_rand_seq   a = dma_rand_seq::type_id::create("a");
    dma_rand_seq   b = dma_rand_seq::type_id::create("b");
    dma_rand_seq   d = dma_rand_seq::type_id::create("d");
    run_seq(c);
    a.n = num_xfers;     a.valid_only = 1; a.inj = 0; run_seq(a);
    b.n = num_xfers / 4; b.valid_only = 0; b.inj = 0; run_seq(b);
    d.n = num_xfers / 2; d.valid_only = 1; d.inj = 1; run_seq(d);
  endtask
endclass
