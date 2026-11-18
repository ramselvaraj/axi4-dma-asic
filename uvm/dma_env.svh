class dma_env extends uvm_env;
  `uvm_component_utils(dma_env)
  dma_agent       agent;
  dma_rd_monitor  rd_mon;
  dma_wr_monitor  wr_mon;
  dma_scoreboard  sb;
  dma_coverage    cov;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent  = dma_agent::type_id::create("agent", this);
    rd_mon = dma_rd_monitor::type_id::create("rd_mon", this);
    wr_mon = dma_wr_monitor::type_id::create("wr_mon", this);
    sb     = dma_scoreboard::type_id::create("sb", this);
    cov    = dma_coverage::type_id::create("cov", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    agent.mon.ap.connect(sb.reg_imp);
    rd_mon.ap.connect(sb.rd_imp);
    wr_mon.ap.connect(sb.wr_imp);
    sb.xfer_ap.connect(cov.analysis_export);
  endfunction
endclass
