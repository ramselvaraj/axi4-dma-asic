// Scoreboard + coverage ---------------------------------------------------------------------------------------
`uvm_analysis_imp_decl(_reg)
`uvm_analysis_imp_decl(_rdb)
`uvm_analysis_imp_decl(_wrb)

class dma_scoreboard extends uvm_component;
  `uvm_component_utils(dma_scoreboard)
  uvm_analysis_imp_reg #(dma_reg_txn, dma_scoreboard) reg_imp;
  uvm_analysis_imp_rdb #(dma_burst,   dma_scoreboard) rd_imp;
  uvm_analysis_imp_wrb #(dma_burst,   dma_scoreboard) wr_imp;
  uvm_analysis_port    #(dma_xfer_rec)                xfer_ap;

  virtual dma_ctl_if ctl;
  mem_access_base    mem;

  // shadow of the programmed registers and of the transfer in flight
  bit [31:0] sh_src, sh_dst, sh_len;
  bit [1:0]  sh_irq_en;
  bit        expect_reset_vals = 1;
  int        n_reset;
  bit        active, cfg_bad, exp_rd_err, exp_wr_err, await_irq_st;
  bit [31:0] exp_ar, exp_aw;
  longint    rd_bytes, wr_bytes;
  int        n_rd, n_wr, max_rd, max_wr, st_rd, st_wr;
  int        n_xfer, n_cfg_bad, n_pass;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    reg_imp = new("reg_imp", this); rd_imp = new("rd_imp", this); wr_imp = new("wr_imp", this);
    xfer_ap = new("xfer_ap", this);
    if (!uvm_config_db#(virtual dma_ctl_if)::get(this, "", "ctl_vif", ctl)) `uvm_fatal("NOVIF", "ctl_vif not set")
    if (!uvm_config_db#(mem_access_base)::get(this, "", "mem", mem))        `uvm_fatal("NOMEM", "mem backdoor not set")
  endfunction

  // a reset in the middle of a transfer: everything returns to its reset value
  task run_phase(uvm_phase phase);
    forever begin
      @(negedge ctl.rst_rd_n);
      sh_src = 0; sh_dst = 0; sh_len = 0; sh_irq_en = 0;
      active = 0; await_irq_st = 0; expect_reset_vals = 1; n_reset++;
    end
  endtask

  function bit predict_cfg_bad();
    return (sh_len == 0) || (sh_len[2:0] != 0) || (sh_src[2:0] != 0) || (sh_dst[2:0] != 0) ||
           ((33'(sh_src) + 33'(sh_len)) > 33'h1_0000_0000) || ((33'(sh_dst) + 33'(sh_len)) > 33'h1_0000_0000);
  endfunction

  function void start_transfer();
    cfg_bad = predict_cfg_bad();
    exp_rd_err = !cfg_bad && ctl.rd_err_en && ctl.rd_err_addr >= sh_src && ctl.rd_err_addr < sh_src + sh_len;
    exp_wr_err = !cfg_bad && ctl.wr_err_en && ctl.wr_err_addr >= sh_dst && ctl.wr_err_addr < sh_dst + sh_len;
    exp_ar = sh_src; exp_aw = sh_dst;
    rd_bytes = 0; wr_bytes = 0; n_rd = 0; n_wr = 0; max_rd = 0; max_wr = 0;
    st_rd = ctl.stall_rd; st_wr = ctl.stall_wr;
    active = 1; await_irq_st = 0;
    `uvm_info("SB", $sformatf("start: src=%08h dst=%08h len=%0d -> expect %s", sh_src, sh_dst, sh_len,
              cfg_bad ? "cfg_err, no bus traffic" : "transfer"), UVM_HIGH)
  endfunction

  function void write_reg(dma_reg_txn t);
    if (t.is_write) begin
      case (t.addr)
        R_SRC:    if (!active) sh_src = t.data;         // locked while a transfer is in flight
        R_DST:    if (!active) sh_dst = t.data;
        R_LEN:    if (!active) sh_len = t.data;
        R_IRQ_EN: sh_irq_en = t.data[1:0];
        R_CTRL:   if (t.data[0] && !active) begin expect_reset_vals = 0; start_transfer(); end
        default: ;
      endcase
    end else begin
      case (t.addr)
        R_SRC:    if (t.data !== sh_src)    `uvm_error("SB", $sformatf("SRC reads %h, expected %h", t.data, sh_src))
        R_DST:    if (t.data !== sh_dst)    `uvm_error("SB", $sformatf("DST reads %h, expected %h", t.data, sh_dst))
        R_LEN:    if (t.data !== sh_len)    `uvm_error("SB", $sformatf("LEN reads %h, expected %h", t.data, sh_len))
        R_IRQ_EN: if (t.data !== {30'd0, sh_irq_en}) `uvm_error("SB", $sformatf("IRQ_EN reads %h, expected %0d", t.data, sh_irq_en))
        default: ;
      endcase
      if (expect_reset_vals && !active && (t.addr == R_STATUS || t.addr == R_IRQ_ST)) begin
        if (t.data !== 32'd0) `uvm_error("SB", $sformatf("register %h reads %h after reset, expected 0", t.addr, t.data))
        if (ctl.irq !== 1'b0) `uvm_error("SB", "irq high after reset")
      end
      if (t.addr == R_STATUS && active && t.data[0] && t.data[1])
        `uvm_error("SB", $sformatf("STATUS=%h: done set while the transfer is still busy (done must clear on START)", t.data))
      if (t.addr == R_STATUS && active && !t.data[0] && (t.data[1] || t.data[4])) finalize(t.data);
      else if (t.addr == R_IRQ_ST && await_irq_st) begin
        await_irq_st = 0;
        if (ctl.irq !== |(t.data[1:0] & sh_irq_en))
          `uvm_error("SB", $sformatf("irq=%0b but IRQ_STATUS=%0d IRQ_EN=%0d", ctl.irq, t.data[1:0], sh_irq_en))
        if (cfg_bad) begin
          if (t.data[1] !== 1'b1) `uvm_error("SB", $sformatf("IRQ_STATUS.err not set after bad config (%h)", t.data))
        end else begin
          if (t.data[0] !== 1'b1) `uvm_error("SB", $sformatf("IRQ_STATUS.done not set (%h)", t.data))
          if (t.data[1] !== (exp_rd_err | exp_wr_err)) `uvm_error("SB", $sformatf("IRQ_STATUS.err=%0b wrong (%h)", t.data[1], t.data))
        end
      end
    end
  endfunction

  function void write_rdb(dma_burst b);
    if (!active) begin `uvm_error("SB", "read burst with no transfer in flight") return; end
    if (cfg_bad)  begin `uvm_error("SB", "read burst after a rejected (bad) configuration") return; end
    if (b.addr !== exp_ar) `uvm_error("SB", $sformatf("AR not contiguous: got %h expected %h", b.addr, exp_ar))
    exp_ar = b.addr + (b.len + 1) * 8;
    rd_bytes += (b.len + 1) * 8; n_rd++; if (b.len + 1 > max_rd) max_rd = b.len + 1;
  endfunction

  function void write_wrb(dma_burst b);
    if (!active) begin `uvm_error("SB", "write burst with no transfer in flight") return; end
    if (cfg_bad)  begin `uvm_error("SB", "write burst after a rejected (bad) configuration") return; end
    if (b.addr !== exp_aw) `uvm_error("SB", $sformatf("AW not contiguous: got %h expected %h", b.addr, exp_aw))
    exp_aw = b.addr + (b.len + 1) * 8;
    if (b.beats != b.len + 1) `uvm_error("SB", $sformatf("burst had %0d W beats, awlen says %0d", b.beats, b.len + 1))
    wr_bytes += (b.len + 1) * 8; n_wr++; if (b.len + 1 > max_wr) max_wr = b.len + 1;
  endfunction

  function void finalize(bit [31:0] st);
    dma_xfer_rec rec = dma_xfer_rec::type_id::create("rec");
    int bad_in = 0, bad_out = 0, bad_src = 0;
    n_xfer++;
    if (cfg_bad) begin
      n_cfg_bad++;
      if (!st[4]) `uvm_error("SB", $sformatf("bad configuration (src=%h dst=%h len=%0d) was not rejected: STATUS=%h", sh_src, sh_dst, sh_len, st))
      if (n_rd != 0 || n_wr != 0) `uvm_error("SB", "bus traffic after a rejected configuration")
    end else begin
      if (!st[1]) `uvm_error("SB", $sformatf("done not set: STATUS=%h", st))
      if (st[4])  `uvm_error("SB", $sformatf("unexpected cfg_err for a valid configuration: STATUS=%h", st))
      if (st[2] !== exp_rd_err) `uvm_error("SB", $sformatf("rd_err=%0b expected %0b", st[2], exp_rd_err))
      if (st[3] !== exp_wr_err) `uvm_error("SB", $sformatf("wr_err=%0b expected %0b", st[3], exp_wr_err))
      if (rd_bytes != sh_len) `uvm_error("SB", $sformatf("read %0d bytes, expected %0d", rd_bytes, sh_len))
      if (wr_bytes != sh_len) `uvm_error("SB", $sformatf("wrote %0d bytes, expected %0d", wr_bytes, sh_len))
      for (int unsigned i = 0; i < MEM_WORDS; i++) begin
        if (mem.rd_src(i) !== mem_access_base::pat(i)) bad_src++;
        if (i * 8 >= sh_dst && i * 8 < sh_dst + sh_len) begin
          if (mem.rd_dst(i) !== mem.rd_src(sh_src / 8 + (i - sh_dst / 8))) bad_in++;
        end else if (mem.rd_dst(i) !== SENTINEL) bad_out++;
      end
      if (bad_in)  `uvm_error("SB", $sformatf("%0d words wrong inside the destination (src=%h dst=%h len=%0d)", bad_in, sh_src, sh_dst, sh_len))
      if (bad_out) `uvm_error("SB", $sformatf("%0d words changed outside the destination", bad_out))
      if (bad_src) `uvm_error("SB", "source memory modified")
      if (!bad_in && !bad_out && !bad_src) n_pass++;
    end
    rec.src = sh_src; rec.dst = sh_dst; rec.len = sh_len; rec.cfg_bad = cfg_bad;
    rec.rd_err = st[2]; rec.wr_err = st[3];
    rec.n_rd_bursts = n_rd; rec.n_wr_bursts = n_wr; rec.max_rd_beats = max_rd; rec.max_wr_beats = max_wr;
    rec.stall_rd = st_rd; rec.stall_wr = st_wr; rec.irq_en = sh_irq_en;
    xfer_ap.write(rec);
    active = 0; await_irq_st = 1;
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("%0d transfers observed: %0d valid transfers with memory fully verified, %0d rejected configurations, %0d resets",
              n_xfer, n_pass, n_cfg_bad, n_reset), UVM_NONE)
    if (active) `uvm_error("SB", "a transfer was still in flight at the end of the test")
  endfunction
endclass

// Functional coverage of the transfers the scoreboard saw.
class dma_coverage extends uvm_subscriber #(dma_xfer_rec);
  `uvm_component_utils(dma_coverage)
  dma_xfer_rec r;
  bit cross_src, cross_dst;

  covergroup cg;
    option.per_instance = 1;
    cp_kind : coverpoint r.cfg_bad { bins valid = {0}; bins rejected = {1}; }
    cp_len  : coverpoint r.len iff (!r.cfg_bad) {
      bins one_beat = {8}; bins short_burst = {[16:120]}; bins one_full_burst = {128};
      bins few_bursts = {[136:1024]}; bins many_bursts = {[1032:8192]}; }
    cp_src_hug : coverpoint cross_src iff (!r.cfg_bad) { bins no = {0}; bins crosses_4k = {1}; }
    cp_dst_hug : coverpoint cross_dst iff (!r.cfg_bad) { bins no = {0}; bins crosses_4k = {1}; }
    cp_maxrd : coverpoint r.max_rd_beats iff (!r.cfg_bad) { bins one = {1}; bins mid = {[2:15]}; bins full16 = {16}; }
    cp_maxwr : coverpoint r.max_wr_beats iff (!r.cfg_bad) { bins one = {1}; bins mid = {[2:15]}; bins full16 = {16}; }
    cp_stall_rd : coverpoint r.stall_rd { bins none = {0}; bins low = {[1:40]}; bins high = {[41:100]}; }
    cp_stall_wr : coverpoint r.stall_wr { bins none = {0}; bins low = {[1:40]}; bins high = {[41:100]}; }
    cp_irq_en : coverpoint r.irq_en { bins masked = {0}; bins done_only = {1}; bins err_only = {2}; bins both = {3}; }
    cp_rd_err : coverpoint r.rd_err iff (!r.cfg_bad) { bins ok = {0}; bins err = {1}; }
    cp_wr_err : coverpoint r.wr_err iff (!r.cfg_bad) { bins ok = {0}; bins err = {1}; }
    cp_cfg_why : coverpoint {r.len == 0, r.len[2:0] != 0, r.src[2:0] != 0, r.dst[2:0] != 0,
                             (33'(r.src) + 33'(r.len)) > 33'h1_0000_0000, (33'(r.dst) + 33'(r.len)) > 33'h1_0000_0000} iff (r.cfg_bad) {
      wildcard bins zero_len      = {6'b1?????};
      wildcard bins len_unaligned = {6'b?1????};
      wildcard bins src_unaligned = {6'b??1???};
      wildcard bins dst_unaligned = {6'b???1??};
      wildcard bins src_overflow  = {6'b????1?};
      wildcard bins dst_overflow  = {6'b?????1}; }
    x_len_stall : cross cp_len, cp_stall_wr;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg = new();
  endfunction

  function void write(dma_xfer_rec t);
    r = t;
    cross_src = ({20'd0, t.src[11:0]} + t.len > 32'd4096);
    cross_dst = ({20'd0, t.dst[11:0]} + t.len > 32'd4096);
    cg.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("functional coverage: %0.1f%%", cg.get_inst_coverage()), UVM_NONE)
  endfunction
endclass
