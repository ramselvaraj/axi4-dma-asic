// Monitors ---------------------------------------------------------------------------------------------------
// AXI4-Lite register monitor: publishes every completed register read/write.
class dma_reg_monitor extends uvm_monitor;
  `uvm_component_utils(dma_reg_monitor)
  virtual axil_if vif;
  uvm_analysis_port #(dma_reg_txn) ap;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual axil_if)::get(this, "", "axil_vif", vif)) `uvm_fatal("NOVIF", "axil_vif not set")
  endfunction
  task run_phase(uvm_phase phase);
    bit [7:0] rd_addr; bit rd_pend = 0;
    dma_reg_txn t;
    forever begin
      @(vif.mon_cb);
      if (!vif.rst_n) begin rd_pend = 0; continue; end
      if (vif.mon_cb.awvalid && vif.mon_cb.awready && vif.mon_cb.wvalid && vif.mon_cb.wready) begin
        t = dma_reg_txn::type_id::create("wr");
        t.is_write = 1; t.addr = vif.mon_cb.awaddr; t.data = vif.mon_cb.wdata;
        ap.write(t);
      end
      if (vif.mon_cb.rvalid && vif.mon_cb.rready && rd_pend) begin
        t = dma_reg_txn::type_id::create("rd");
        t.is_write = 0; t.addr = rd_addr; t.data = vif.mon_cb.rdata;
        if (vif.mon_cb.rresp !== 2'b00) `uvm_error("AXIL", "read response not OKAY")
        rd_pend = 0;
        ap.write(t);
      end
      if (vif.mon_cb.bvalid && vif.mon_cb.bready && vif.mon_cb.bresp !== 2'b00)
        `uvm_error("AXIL", "write response not OKAY")
      if (vif.mon_cb.arvalid && vif.mon_cb.arready) begin rd_addr = vif.mon_cb.araddr; rd_pend = 1; end
    end
  endtask
endclass

// AXI4 read-master monitor (clk_rd): AR/R protocol checks, publishes one dma_burst per completed read burst.
class dma_rd_monitor extends uvm_monitor;
  `uvm_component_utils(dma_rd_monitor)
  virtual axi_rd_if vif;
  uvm_analysis_port #(dma_burst) ap;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual axi_rd_if)::get(this, "", "rd_vif", vif)) `uvm_fatal("NOVIF", "rd_vif not set")
  endfunction
  task run_phase(uvm_phase phase);
    bit p_valid = 0, p_ready = 0; bit [31:0] p_addr; bit [7:0] p_len;
    dma_burst q[$]; int beats = 0; dma_burst b;
    forever begin
      @(vif.mon_cb);
      if (!vif.rst_n) begin p_valid = 0; q.delete(); beats = 0; continue; end
      if (p_valid && !p_ready && (!vif.mon_cb.arvalid || vif.mon_cb.araddr !== p_addr || vif.mon_cb.arlen !== p_len))
        `uvm_error("AXI_RD", "AR changed or dropped before ARREADY")
      if (vif.mon_cb.arvalid && vif.mon_cb.arready) begin
        if (vif.mon_cb.arlen > 8'd15) `uvm_error("AXI_RD", $sformatf("burst longer than 16 beats (arlen=%0d)", vif.mon_cb.arlen))
        if (vif.mon_cb.araddr[2:0] != 0) `uvm_error("AXI_RD", $sformatf("AR address %h not 8-byte aligned", vif.mon_cb.araddr))
        if ({20'd0, vif.mon_cb.araddr[11:0]} + (32'(vif.mon_cb.arlen) + 1) * 8 > 32'd4096)
          `uvm_error("AXI_RD", $sformatf("burst at %h len %0d crosses a 4 KiB boundary", vif.mon_cb.araddr, vif.mon_cb.arlen))
        b = dma_burst::type_id::create("rd_burst");
        b.is_write = 0; b.addr = vif.mon_cb.araddr; b.len = vif.mon_cb.arlen;
        q.push_back(b);
      end
      p_valid = vif.mon_cb.arvalid; p_ready = vif.mon_cb.arready; p_addr = vif.mon_cb.araddr; p_len = vif.mon_cb.arlen;
      if (vif.mon_cb.rvalid && vif.mon_cb.rready) begin
        if (q.size() == 0) `uvm_error("AXI_RD", "R beat with no outstanding AR")
        else begin
          beats++;
          if (vif.mon_cb.rlast !== (beats == q[0].len + 1)) `uvm_error("AXI_RD", "RLAST wrong")
          if (beats == q[0].len + 1 || vif.mon_cb.rlast) begin
            b = q.pop_front(); b.beats = beats; beats = 0;
            ap.write(b);
          end
        end
      end
    end
  endtask
endclass

// AXI4 write-master monitor (clk_wr): AW/W/B protocol checks, publishes one dma_burst per completed write burst.
class dma_wr_monitor extends uvm_monitor;
  `uvm_component_utils(dma_wr_monitor)
  virtual axi_wr_if vif;
  uvm_analysis_port #(dma_burst) ap;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual axi_wr_if)::get(this, "", "wr_vif", vif)) `uvm_fatal("NOVIF", "wr_vif not set")
  endfunction
  task run_phase(uvm_phase phase);
    bit pa_v = 0, pa_r = 0, pw_v = 0, pw_r = 0; bit [31:0] pa_addr; bit [7:0] pa_len; bit [63:0] pw_data; bit pw_last;
    dma_burst aw_q[$], b_q[$]; int beats = 0; dma_burst b;
    forever begin
      @(vif.mon_cb);
      if (!vif.rst_n) begin pa_v = 0; pw_v = 0; aw_q.delete(); b_q.delete(); beats = 0; continue; end
      if (pa_v && !pa_r && (!vif.mon_cb.awvalid || vif.mon_cb.awaddr !== pa_addr || vif.mon_cb.awlen !== pa_len))
        `uvm_error("AXI_WR", "AW changed or dropped before AWREADY")
      if (pw_v && !pw_r && (!vif.mon_cb.wvalid || vif.mon_cb.wdata !== pw_data || vif.mon_cb.wlast !== pw_last))
        `uvm_error("AXI_WR", "W changed or dropped before WREADY")
      if (vif.mon_cb.awvalid && vif.mon_cb.awready) begin
        if (vif.mon_cb.awlen > 8'd15) `uvm_error("AXI_WR", $sformatf("burst longer than 16 beats (awlen=%0d)", vif.mon_cb.awlen))
        if (vif.mon_cb.awaddr[2:0] != 0) `uvm_error("AXI_WR", $sformatf("AW address %h not 8-byte aligned", vif.mon_cb.awaddr))
        if ({20'd0, vif.mon_cb.awaddr[11:0]} + (32'(vif.mon_cb.awlen) + 1) * 8 > 32'd4096)
          `uvm_error("AXI_WR", $sformatf("burst at %h len %0d crosses a 4 KiB boundary", vif.mon_cb.awaddr, vif.mon_cb.awlen))
        b = dma_burst::type_id::create("wr_burst");
        b.is_write = 1; b.addr = vif.mon_cb.awaddr; b.len = vif.mon_cb.awlen;
        aw_q.push_back(b);
      end
      if (vif.mon_cb.wvalid && vif.mon_cb.wready) begin
        if (aw_q.size() == 0) `uvm_error("AXI_WR", "W beat with no outstanding AW")
        else begin
          beats++;
          if (vif.mon_cb.wlast !== (beats == aw_q[0].len + 1)) `uvm_error("AXI_WR", "WLAST wrong")
          if (vif.mon_cb.wstrb !== 8'hFF) `uvm_error("AXI_WR", "WSTRB not all ones")
          if (beats == aw_q[0].len + 1) begin
            b = aw_q.pop_front(); b.beats = beats; beats = 0; b_q.push_back(b);
          end
        end
      end
      if (vif.mon_cb.bvalid && vif.mon_cb.bready) begin
        if (b_q.size() == 0) `uvm_error("AXI_WR", "B response with no completed write burst")
        else begin b = b_q.pop_front(); ap.write(b); end
      end
      pa_v = vif.mon_cb.awvalid; pa_r = vif.mon_cb.awready; pa_addr = vif.mon_cb.awaddr; pa_len = vif.mon_cb.awlen;
      pw_v = vif.mon_cb.wvalid; pw_r = vif.mon_cb.wready; pw_data = vif.mon_cb.wdata; pw_last = vif.mon_cb.wlast;
    end
  endtask
endclass
