// AXI4-Lite agent: sequencer, driver, register monitor --------------------------------------------------------
typedef uvm_sequencer #(dma_item) dma_sequencer;

class dma_driver extends uvm_driver #(dma_item);
  `uvm_component_utils(dma_driver)
  virtual axil_if    vif;
  virtual dma_ctl_if ctl;
  mem_access_base    mem;
  real rd_halves[4] = '{2.5, 5.0, 7.0, 10.0};
  real wr_halves[5] = '{1.6, 3.2, 5.0, 9.1, 12.8};

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axil_if)::get(this, "", "axil_vif", vif))       `uvm_fatal("NOVIF", "axil_vif not set")
    if (!uvm_config_db#(virtual dma_ctl_if)::get(this, "", "ctl_vif", ctl))     `uvm_fatal("NOVIF", "ctl_vif not set")
    if (!uvm_config_db#(mem_access_base)::get(this, "", "mem", mem))            `uvm_fatal("NOMEM", "mem backdoor not set")
  endfunction

  task axil_write(bit [7:0] a, bit [31:0] d);
    @(vif.drv_cb);
    vif.drv_cb.awaddr <= a; vif.drv_cb.awvalid <= 1; vif.drv_cb.wdata <= d; vif.drv_cb.wstrb <= 4'hf; vif.drv_cb.wvalid <= 1;
    do @(vif.drv_cb); while (!(vif.drv_cb.awready && vif.drv_cb.wready));
    vif.drv_cb.awvalid <= 0; vif.drv_cb.wvalid <= 0;
  endtask

  task axil_read(bit [7:0] a, output bit [31:0] d);
    @(vif.drv_cb);
    vif.drv_cb.araddr <= a; vif.drv_cb.arvalid <= 1;
    do @(vif.drv_cb); while (!vif.drv_cb.arready);
    vif.drv_cb.arvalid <= 0;
    do @(vif.drv_cb); while (!vif.drv_cb.rvalid);
    d = vif.drv_cb.rdata;
  endtask

  task run_phase(uvm_phase phase);
    bit [31:0] r;
    vif.drv_cb.awvalid <= 0; vif.drv_cb.wvalid <= 0; vif.drv_cb.arvalid <= 0;
    vif.drv_cb.bready <= 1;  vif.drv_cb.rready <= 1;
    wait (ctl.rst_rd_n === 1'b1 && ctl.rst_wr_n === 1'b1);
    repeat (5) @(vif.drv_cb);
    read_all_regs();                      // reset values (scoreboard checks them)
    forever begin
      seq_item_port.get_next_item(req);
      do_item(req);
      seq_item_port.item_done();
    end
  endtask

  // read every register once; the scoreboard compares them with its shadow / the reset values
  task read_all_regs();
    bit [31:0] r;
    axil_read(R_STATUS, r); axil_read(R_SRC, r); axil_read(R_DST, r); axil_read(R_LEN, r);
    axil_read(R_IRQ_EN, r); axil_read(R_IRQ_ST, r);
  endtask

  task do_reset();
    ctl.rst_rd_n = 0; ctl.rst_wr_n = 0;
    repeat (5) @(vif.drv_cb);
    ctl.rst_rd_n = 1;
    repeat (4) @(vif.drv_cb);
    ctl.rst_wr_n = 1;
    repeat (5) @(vif.drv_cb);
  endtask

  task do_item(dma_item it);
    bit [31:0] r;
    int cycles = 0, cap;
    `uvm_info("DRV", it.convert2string(), UVM_MEDIUM)
    ctl.rd_half = rd_halves[it.rd_clk];
    ctl.wr_half = wr_halves[it.wr_clk];
    ctl.stall_rd = it.stall_rd; ctl.stall_wr = it.stall_wr;
    mem.fill();
    ctl.rd_err_en = it.inj_rd_err; ctl.rd_err_addr = it.src + 8 * it.rd_err_beat;
    ctl.wr_err_en = it.inj_wr_err; ctl.wr_err_addr = it.dst + 8 * it.wr_err_beat;
    axil_write(R_IRQ_EN, {30'd0, it.irq_en});
    axil_write(R_SRC, it.src); axil_write(R_DST, it.dst); axil_write(R_LEN, it.len);
    axil_write(R_CTRL, 32'h1);
    if (it.do_reset) begin
      repeat (it.reset_delay) @(vif.drv_cb);
      do_reset();
      read_all_regs();                    // everything back at reset values, irq low
      ctl.rd_err_en = 0; ctl.wr_err_en = 0;
      return;
    end
    if (it.poke) begin                    // the DMA is busy: these writes must change nothing
      axil_write(R_SRC, 32'h3000); axil_write(R_DST, 32'h4000); axil_write(R_LEN, 32'd8);
      axil_write(R_CTRL, 32'h1);
    end
    cap = 5000 + (it.len / 8) * 600;
    do begin
      repeat (6) @(vif.drv_cb); cycles += 6;
      axil_read(R_STATUS, r); cycles += 4;
    end while (!(!r[0] && (r[1] || r[4])) && cycles < cap);
    if (r[0] || !(r[1] || r[4])) `uvm_fatal("TIMEOUT", $sformatf("not finished after %0d cycles: %s", cap, it.convert2string()))
    repeat (3) @(vif.drv_cb);
    axil_read(R_IRQ_ST, r);               // scoreboard checks IRQ_STATUS bits and the irq level against IRQ_EN
    read_all_regs();                      // readback of SRC/DST/LEN/IRQ_EN (locked while busy)
    axil_write(R_IRQ_ST, 32'h3);
    repeat (3) @(vif.drv_cb);
    if (ctl.irq) `uvm_error("DRV", "irq stuck high after write-1-to-clear")
    ctl.rd_err_en = 0; ctl.wr_err_en = 0;
  endtask
endclass

class dma_agent extends uvm_agent;
  `uvm_component_utils(dma_agent)
  dma_sequencer sqr;
  dma_driver    drv;
  dma_reg_monitor mon;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = dma_sequencer::type_id::create("sqr", this);
    drv = dma_driver::type_id::create("drv", this);
    mon = dma_reg_monitor::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
