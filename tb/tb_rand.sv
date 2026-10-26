`timescale 1ns/1ps
// Randomized + directed stress test.
//  - random clock ratios, sizes, 4KB-edge addresses, backpressure, AXI errors
//  - protocol checker on both AXI masters and the FIFO
//  - scoreboard: destination equals source, nothing outside destination changed
// Build with -GFIFO_AW=n -GITER=n, run with +verilator+seed+N.
module tb_rand #(
  parameter int FIFO_AW = 5,
  parameter int ITER    = 200
);

  localparam int SPEC_MAX_BEATS = 16;   // independent of the RTL constant
  localparam int MEM_WORDS = 1 << 14;
  localparam int MEM_BYTES = MEM_WORDS * 8;
  localparam [63:0] SENTINEL = 64'hDEAD_BEEF_0BAD_F00D;

  logic clk_rd = 0, clk_wr = 0, rst_rd_n = 0, rst_wr_n = 0;
  real rd_half = 5.0, wr_half = 3.2;
  initial forever #(rd_half) clk_rd = ~clk_rd;
  initial forever #(wr_half) clk_wr = ~clk_wr;

  logic [7:0] awaddr, araddr_l; logic awvalid, wvalid, arvalid_l, bready = 1, rready_l = 1;
  logic [31:0] wdata_l, rdata_l; logic awready, wready, bvalid, arready_l, rvalid_l;
  logic [1:0] bresp_l, rresp_l;
  logic [31:0] m_araddr; logic [7:0] m_arlen; logic m_arvalid, m_arready;
  logic m_rvalid, m_rready, m_rlast; logic [63:0] m_rdata; logic [1:0] m_rresp;
  logic [31:0] m_awaddr; logic [7:0] m_awlen; logic m_awvalid, m_awready;
  logic m_wvalid, m_wready, m_wlast; logic [63:0] m_wdata; logic [7:0] m_wstrb;
  logic m_bvalid, m_bready; logic [1:0] m_bresp;
  logic irq;

  dma_top #(.FIFO_AW(FIFO_AW)) dut (
    .clk_rd, .rst_rd_n, .clk_wr, .rst_wr_n,
    .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready),
    .s_wdata(wdata_l), .s_wstrb(4'hf), .s_wvalid(wvalid), .s_wready(wready),
    .s_bresp(bresp_l), .s_bvalid(bvalid), .s_bready(bready),
    .s_araddr(araddr_l), .s_arvalid(arvalid_l), .s_arready(arready_l),
    .s_rdata(rdata_l), .s_rresp(rresp_l), .s_rvalid(rvalid_l), .s_rready(rready_l),
    .m_araddr, .m_arlen, .m_arvalid, .m_arready, .m_rvalid, .m_rready, .m_rdata, .m_rresp, .m_rlast,
    .m_awaddr, .m_awlen, .m_awvalid, .m_awready, .m_wvalid, .m_wready, .m_wdata, .m_wstrb, .m_wlast,
    .m_bvalid, .m_bready, .m_bresp, .irq
  );

  axi4_mem_model #(.DDR_MODE(0), .SIMPLE_LAT(2)) u_src (
    .clk(clk_rd), .rst_n(rst_rd_n),
    .araddr(m_araddr), .arlen(m_arlen), .arvalid(m_arvalid), .arready(m_arready),
    .rvalid(m_rvalid), .rready(m_rready), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast),
    .awaddr('0), .awlen('0), .awvalid(1'b0), .awready(),
    .wvalid(1'b0), .wready(), .wdata('0), .wstrb('0), .wlast(1'b0),
    .bvalid(), .bready(1'b1), .bresp()
  );

  axi4_mem_model #(.DDR_MODE(1), .TREFI(150), .TRFC(20)) u_ddr (
    .clk(clk_wr), .rst_n(rst_wr_n),
    .araddr('0), .arlen('0), .arvalid(1'b0), .arready(),
    .rvalid(), .rready(1'b1), .rdata(), .rresp(), .rlast(),
    .awaddr(m_awaddr), .awlen(m_awlen), .awvalid(m_awvalid), .awready(m_awready),
    .wvalid(m_wvalid), .wready(m_wready), .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast),
    .bvalid(m_bvalid), .bready(m_bready), .bresp(m_bresp)
  );

  // ------------------------------------------------------------------
  // bookkeeping
  // ------------------------------------------------------------------
  int errors = 0;
  task automatic fail(input string msg);
    errors++;
    if (errors <= 20) $display("[%0t] FAIL: %s", $time, msg);
  endtask

  // ------------------------------------------------------------------
  // protocol checker
  // ------------------------------------------------------------------
  bit          chk_en = 0;
  int unsigned ar_bytes, aw_bytes, w_bytes, b_count, aw_count;
  logic [31:0] exp_ar, exp_aw;

  // read master (clk_rd)
  logic p_arvalid, p_arready; logic [31:0] p_araddr; logic [7:0] p_arlen;
  logic p_fifo_full_chk;
  always @(posedge clk_rd) begin
    if (!rst_rd_n) p_arvalid <= 0;
    else begin
      if (p_arvalid && !p_arready && (!m_arvalid || m_araddr !== p_araddr || m_arlen !== p_arlen))
        fail("AR changed or dropped before arready");
      if (m_arvalid && m_arready && chk_en) begin
        if (m_arlen > 8'(SPEC_MAX_BEATS-1))                       fail("AR burst longer than 16 beats");
        if (m_araddr[2:0] != 0)                              fail("AR address not 8-byte aligned");
        if ({20'd0, m_araddr[11:0]} + (32'(m_arlen)+1)*8 > 32'd4096) fail("AR burst crosses 4KB");
        if (m_araddr !== exp_ar)                             fail($sformatf("AR not contiguous: got %h exp %h", m_araddr, exp_ar));
        exp_ar   <= exp_ar + (32'(m_arlen)+1)*8;
        ar_bytes <= ar_bytes + (32'(m_arlen)+1)*8;
      end
      p_arvalid <= m_arvalid; p_arready <= m_arready; p_araddr <= m_araddr; p_arlen <= m_arlen;
      if (dut.fifo_winc && dut.fifo_wfull) fail("FIFO overflow");
    end
  end

  // write master (clk_wr)
  logic p_awvalid, p_awready, p_wvalid, p_wready;
  logic [31:0] p_awaddr; logic [7:0] p_awlen; logic [63:0] p_wdata; logic p_wlast;
  int aw_q [$];
  int cur_beat;
  always @(posedge clk_wr) begin
    if (!rst_wr_n) begin
      p_awvalid <= 0; p_wvalid <= 0; aw_q.delete(); cur_beat = 0;
    end else begin
      if (p_awvalid && !p_awready && (!m_awvalid || m_awaddr !== p_awaddr || m_awlen !== p_awlen))
        fail("AW changed or dropped before awready");
      if (p_wvalid && !p_wready && (!m_wvalid || m_wdata !== p_wdata || m_wlast !== p_wlast))
        fail("W changed or dropped before wready");

      if (m_awvalid && m_awready && chk_en) begin
        if (m_awlen > 8'(SPEC_MAX_BEATS-1))                       fail("AW burst longer than 16 beats");
        if (m_awaddr[2:0] != 0)                              fail("AW address not 8-byte aligned");
        if ({20'd0, m_awaddr[11:0]} + (32'(m_awlen)+1)*8 > 32'd4096) fail("AW burst crosses 4KB");
        if (m_awaddr !== exp_aw)                             fail($sformatf("AW not contiguous: got %h exp %h", m_awaddr, exp_aw));
        exp_aw   <= exp_aw + (32'(m_awlen)+1)*8;
        aw_bytes <= aw_bytes + (32'(m_awlen)+1)*8;
        aw_count <= aw_count + 1;
        aw_q.push_back(int'(m_awlen));
      end
      if (m_wvalid && m_wready && chk_en) begin
        if (aw_q.size() == 0) fail("W beat with no outstanding AW");
        else begin
          cur_beat = cur_beat + 1;
          if (m_wlast !== (cur_beat == aw_q[0] + 1)) fail("WLAST wrong");
          if (m_wstrb !== 8'hFF)                     fail("WSTRB not all ones");
          w_bytes <= w_bytes + 8;
          if (cur_beat == aw_q[0] + 1) begin aw_q.pop_front(); cur_beat = 0; end
        end
      end
      if (m_bvalid && m_bready && chk_en) b_count <= b_count + 1;
      if (dut.fifo_rinc && dut.fifo_rempty) fail("FIFO underflow");

      p_awvalid <= m_awvalid; p_awready <= m_awready; p_awaddr <= m_awaddr; p_awlen <= m_awlen;
      p_wvalid <= m_wvalid; p_wready <= m_wready; p_wdata <= m_wdata; p_wlast <= m_wlast;
    end
  end

  // event trace (+v)
  always @(posedge dut.start)      if ($test$plusargs("trace")) $display("   [%0t] start (rd)", $time);
  always @(posedge dut.start_wr)   if ($test$plusargs("trace")) $display("   [%0t] start_wr", $time);
  always @(posedge dut.wr_done)    if ($test$plusargs("trace")) $display("   [%0t] wr_done", $time);
  always @(posedge dut.done_rd_d)  if ($test$plusargs("trace")) $display("   [%0t] done_rd_d", $time);
  always @(posedge clk_rd) if ($test$plusargs("trace") && m_arvalid && m_arready) $display("   [%0t] AR %h len=%0d chk_en=%0b", $time, m_araddr, m_arlen, chk_en);
  always @(posedge clk_wr) if ($test$plusargs("trace") && m_awvalid && m_awready) $display("   [%0t] AW %h len=%0d", $time, m_awaddr, m_awlen);
  always @(posedge clk_rd) if ($test$plusargs("tracecyc") && $time > 87850 && $time < 88100)
    $display("   [%0t] arv=%b arr=%b st=%0d a_stall=%b rv=%b rr=%b fifo_w=%b full=%b ar_busy=%b cur=%h rem=%0d", $time, m_arvalid, m_arready, u_src.st, u_src.a_stall, m_rvalid, m_rready, dut.fifo_winc, dut.fifo_wfull, dut.u_rd.ar_busy, dut.u_rd.cur, dut.u_rd.rem);
  always @(posedge clk_wr) if ($test$plusargs("tracecyc") && $time > 65190 && $time < 65600)
    $display("   [%0t] wr: st=%0d wv=%b wr=%b rempty=%b ddr_st=%0d wstall=%b lat=%0d bv=%b br=%b", $time, dut.u_wr.st, m_wvalid, m_wready, dut.fifo_rempty, u_ddr.st, u_ddr.w_stall, u_ddr.lat_cnt, m_bvalid, m_bready);
  always @(posedge irq)            if ($test$plusargs("trace")) $display("   [%0t] irq up", $time);
  always @(negedge irq)            if ($test$plusargs("trace")) $display("   [%0t] irq down", $time);

  // ------------------------------------------------------------------
  // AXI-Lite helpers
  // ------------------------------------------------------------------
  task automatic axil_write(input [7:0] a, input [31:0] d);
    @(posedge clk_rd); awaddr <= a; awvalid <= 1; wdata_l <= d; wvalid <= 1;
    @(posedge clk_rd); while (!(awready && wready)) @(posedge clk_rd);
    awvalid <= 0; wvalid <= 0;
  endtask

  task automatic axil_read(input [7:0] a, output [31:0] d);
    @(posedge clk_rd); araddr_l <= a; arvalid_l <= 1;
    @(posedge clk_rd); while (!arready_l) @(posedge clk_rd);
    arvalid_l <= 0;
    @(posedge clk_rd); while (!rvalid_l) @(posedge clk_rd);
    d = rdata_l;
  endtask

  localparam [7:0] CTRL=8'h00, STATUS=8'h04, SRC=8'h08, DST=8'h0C, LEN=8'h10,
                   IRQ_EN=8'h14, IRQ_ST=8'h18;

  // ------------------------------------------------------------------
  // helpers
  // ------------------------------------------------------------------
  function automatic [63:0] pat(input int i);
    return {32'hC0DE0000 ^ 32'(i), ~(32'(i) * 32'd2654435761)};
  endfunction

  task automatic fill_mems();
    for (int i = 0; i < MEM_WORDS; i++) begin
      u_src.mem[i] = pat(i);
      u_ddr.mem[i] = SENTINEL;
    end
  endtask

  function automatic int rnd(input int lo, input int hi);
    return int'($urandom_range(hi, lo));
  endfunction

  // aligned address for a transfer of len bytes; often hugs a 4KB boundary
  function automatic int pick_addr(input int len);
    int a, page;
    if (rnd(0, 2) == 0) begin
      page = rnd(1, MEM_BYTES / 4096 - 1);
      a = page * 4096 - 8 * rnd(0, 20);
    end else begin
      a = rnd(0, (MEM_BYTES - len) / 8) * 8;
    end
    if (a < 0) a = 0;
    if (a + len > MEM_BYTES) a = ((MEM_BYTES - len) / 8) * 8;
    return a;
  endfunction

  function automatic int pick_len();
    case (rnd(0, 9))
      0: return 8;
      1: return 8 * rnd(2, 16);
      2: return 128;                    // exactly one full burst
      3: return 8 * rnd(17, 40);
      4: return 8 * rnd(100, 600);
      5: return 8 * rnd(600, 1400);
      default: return 8 * rnd(1, 300);
    endcase
  endfunction

  function automatic int pick_stall();
    case (rnd(0, 5))
      0, 1: return 0;
      2:    return 15;
      3:    return 40;
      4:    return 70;
      default: return 92;
    endcase
  endfunction

  task automatic pick_clocks();
    case (rnd(0, 3)) 0: rd_half = 2.5; 1: rd_half = 5.0; 2: rd_half = 7.0; default: rd_half = 10.0; endcase
    case (rnd(0, 4)) 0: wr_half = 1.6; 1: wr_half = 3.2; 2: wr_half = 5.0; 3: wr_half = 9.1; default: wr_half = 12.8; endcase
  endtask

  // Compare memories after a transfer. Returns nothing; reports failures.
  task automatic scoreboard(input int src_b, input int dst_b, input int len_b, input string tag);
    int bad_in = 0, bad_out = 0, bad_src = 0;
    for (int i = 0; i < MEM_WORDS; i++) begin
      if (u_src.mem[i] !== pat(i)) bad_src++;
      if (i*8 >= dst_b && i*8 < dst_b + len_b) begin
        if (u_ddr.mem[i] !== u_src.mem[src_b/8 + (i - dst_b/8)]) bad_in++;
      end else if (u_ddr.mem[i] !== SENTINEL) bad_out++;
    end
    if (bad_in)  fail($sformatf("%s: %0d words wrong inside destination", tag, bad_in));
    if (bad_out) fail($sformatf("%s: %0d words changed outside destination", tag, bad_out));
    if (bad_src) fail($sformatf("%s: source memory modified", tag));
  endtask

  // Wait for irq or timeout (rd-clock cycles). Returns 1 on timeout.
  task automatic wait_irq(input int cap, output bit timed_out);
    int c = 0;
    while (!irq && c < cap) begin @(posedge clk_rd); c++; end
    timed_out = !irq;
  endtask

  task automatic arm_checker(input int src_b, input int dst_b);
    ar_bytes = 0; aw_bytes = 0; w_bytes = 0; b_count = 0; aw_count = 0;
    exp_ar = src_b; exp_aw = dst_b; chk_en = 1;
  endtask

  task automatic start_dma(input int src_b, input int dst_b, input int len_b);
    axil_write(IRQ_EN, 2'b11);
    axil_write(SRC, src_b); axil_write(DST, dst_b); axil_write(LEN, len_b);
    axil_write(CTRL, 1);
  endtask

  // One full transfer with all checks. rd_err/wr_err inject AXI error responses.
  task automatic do_transfer(input int src_b, input int dst_b, input int len_b,
                             input bit inj_rd_err, input bit inj_wr_err, input string tag);
    logic [31:0] r;
    bit to;
    int cap = 5000 + (len_b / 8) * 600;
    if ($test$plusargs("trace")) $display("[%0t] %s rd_err=%0b wr_err=%0b rd_half=%0f wr_half=%0f stall=%0d/%0d",
        $time, tag, inj_rd_err, inj_wr_err, rd_half, wr_half, u_src.stall_pct, u_ddr.stall_pct);
    fill_mems();
    u_src.err_en = inj_rd_err; u_ddr.err_en = inj_wr_err;
    if (inj_rd_err) begin
      u_src.err_lo = src_b + 8 * rnd(0, len_b/8 - 1); u_src.err_hi = u_src.err_lo;
    end
    if (inj_wr_err) begin
      u_ddr.err_lo = dst_b + 8 * rnd(0, len_b/8 - 1); u_ddr.err_hi = u_ddr.err_lo;
    end
    arm_checker(src_b, dst_b);
    start_dma(src_b, dst_b, len_b);
    wait_irq(cap, to);
    if (to) begin fail($sformatf("%s: timeout waiting for irq", tag)); return; end
    if (ar_bytes == 0 && $test$plusargs("trace")) begin
      axil_read(STATUS, r); $display("   early irq: STATUS=%h", r);
      axil_read(IRQ_ST, r); $display("   early irq: IRQ_ST=%h", r);
    end
    repeat (3) @(posedge clk_rd);
    chk_en = 0;

    axil_read(STATUS, r);
    if (r[0])                     fail($sformatf("%s: still busy after irq", tag));
    if (!r[1])                    fail($sformatf("%s: done not set", tag));
    if (r[2] !== inj_rd_err)      fail($sformatf("%s: rd_err=%0b expected %0b", tag, r[2], inj_rd_err));
    if (r[3] !== inj_wr_err)      fail($sformatf("%s: wr_err=%0b expected %0b", tag, r[3], inj_wr_err));
    if (r[4])                     fail($sformatf("%s: unexpected cfg_err", tag));
    axil_read(IRQ_ST, r);
    if (r[0] !== 1'b1)            fail($sformatf("%s: IRQ_STATUS.done not set", tag));
    if (r[1] !== (inj_rd_err | inj_wr_err)) fail($sformatf("%s: IRQ_STATUS.err=%0b wrong", tag, r[1]));

    if (ar_bytes !== len_b) fail($sformatf("%s: read %0d bytes expected %0d", tag, ar_bytes, len_b));
    if (aw_bytes !== len_b) fail($sformatf("%s: AW covers %0d bytes expected %0d", tag, aw_bytes, len_b));
    if (w_bytes  !== len_b) fail($sformatf("%s: wrote %0d bytes expected %0d", tag, w_bytes, len_b));
    if (b_count  !== aw_count) fail($sformatf("%s: %0d B responses for %0d bursts", tag, b_count, aw_count));
    scoreboard(src_b, dst_b, len_b, tag);

    axil_write(IRQ_ST, 2'b11);
    repeat (3) @(posedge clk_rd);
    if (irq) fail($sformatf("%s: irq stuck after W1C", tag));
    u_src.err_en = 0; u_ddr.err_en = 0;
  endtask

  task automatic do_reset();
    rst_rd_n <= 0; rst_wr_n <= 0;
    chk_en = 0;
    repeat (5) @(posedge clk_rd);
    rst_rd_n <= 1;
    repeat (3) @(posedge clk_wr);
    rst_wr_n <= 1;
    repeat (5) @(posedge clk_rd);
  endtask

  // ------------------------------------------------------------------
  // main
  // ------------------------------------------------------------------
  logic [31:0] r;
  int src_b, dst_b, len_b, n_rd_err, n_wr_err, n_bytes;
  bit inj_r, inj_w, to;

  initial begin
    awvalid = 0; wvalid = 0; arvalid_l = 0; awaddr = 0; wdata_l = 0; araddr_l = 0;
    fill_mems();
    repeat (5) @(posedge clk_rd);
    rst_rd_n = 1; rst_wr_n = 1;
    repeat (5) @(posedge clk_rd);
    $display("tb_rand: FIFO_AW=%0d ITER=%0d", FIFO_AW, ITER);

    // ---- D1: bad configs must be rejected without any bus traffic -------------
    $display("[D1] bad configs");
    for (int k = 0; k < 4; k++) begin
      arm_checker(0, 0);
      axil_write(IRQ_EN, 2'b11);
      axil_write(SRC, (k == 1) ? 32'h4 : 32'h1000);
      axil_write(DST, (k == 2) ? 32'h2 : 32'h2000);
      axil_write(LEN, (k == 0) ? 32'd0 : (k == 3) ? 32'd12 : 32'd64);
      axil_write(CTRL, 1);
      repeat (20) @(posedge clk_rd);
      axil_read(STATUS, r);
      if (!r[4] || r[0])      fail($sformatf("D1.%0d: cfg_err/busy wrong, STATUS=%h", k, r));
      if (!irq)               fail($sformatf("D1.%0d: no error irq", k));
      if (ar_bytes != 0 || aw_bytes != 0) fail($sformatf("D1.%0d: bus traffic after bad config", k));
      axil_write(IRQ_ST, 2'b11);
    end
    chk_en = 0;

    // ---- D2: registers lock while busy; second START is ignored --------------
    $display("[D2] config locked while busy");
    do_transfer(32'h0, 32'h0, 64, 0, 0, "D2 warmup");   // leaves STATUS.done = 1
    fill_mems();
    arm_checker(32'h100, 32'h900);
    start_dma(32'h100, 32'h900, 2048);
    repeat (6) @(posedge clk_rd);
    axil_read(STATUS, r);
    if (r[1:0] !== 2'b01) fail($sformatf("D2: STATUS=%h while running, expected busy=1 done=0", r));
    axil_write(SRC, 32'h3000); axil_write(DST, 32'h4000); axil_write(LEN, 8);
    axil_write(CTRL, 1);
    axil_read(SRC, r); if (r !== 32'h100) fail("D2: SRC changed while busy");
    axil_read(DST, r); if (r !== 32'h900) fail("D2: DST changed while busy");
    axil_read(LEN, r); if (r !== 32'd2048) fail("D2: LEN changed while busy");
    wait_irq(100000, to);
    if (to) fail("D2: timeout");
    repeat (3) @(posedge clk_rd); chk_en = 0;
    if (ar_bytes != 2048 || w_bytes != 2048) fail("D2: second START was not ignored");
    scoreboard(32'h100, 32'h900, 2048, "D2");
    axil_write(IRQ_ST, 2'b11);

    // ---- D3: IRQ masked, poll STATUS instead ---------------------------------
    $display("[D3] masked interrupt");
    fill_mems();
    axil_write(IRQ_EN, 2'b00);
    axil_write(SRC, 32'h0); axil_write(DST, 32'h0); axil_write(LEN, 512);
    axil_write(CTRL, 1);
    r = 1;
    for (int c = 0; c < 4000 && r[0]; c++) begin
      axil_read(STATUS, r);
      if (irq) fail("D3: irq high while masked");
    end
    if (r[0]) fail("D3: never finished");
    axil_read(IRQ_ST, r); if (r[0] !== 1'b1) fail("D3: IRQ_STATUS.done not set while masked");
    scoreboard(0, 0, 512, "D3");
    axil_write(IRQ_ST, 2'b11);

    // ---- D4: reset in the middle of a transfer -------------------------------
    $display("[D4] reset during transfer");
    for (int k = 0; k < 10; k++) begin
      pick_clocks();
      u_src.stall_pct = pick_stall(); u_ddr.stall_pct = pick_stall();
      fill_mems();
      start_dma(32'h400, 32'h8000, 4096);
      repeat (rnd(3, 600)) @(posedge clk_rd);
      do_reset();
      axil_read(STATUS, r);   if (r !== 32'd0) fail($sformatf("D4.%0d: STATUS=%h after reset", k, r));
      axil_read(SRC, r);      if (r !== 32'd0) fail($sformatf("D4.%0d: SRC not cleared", k));
      axil_read(DST, r);      if (r !== 32'd0) fail($sformatf("D4.%0d: DST not cleared", k));
      axil_read(LEN, r);      if (r !== 32'd0) fail($sformatf("D4.%0d: LEN not cleared", k));
      axil_read(8'h14, r);    if (r !== 32'd0) fail($sformatf("D4.%0d: IRQ_EN not cleared", k));
      axil_read(IRQ_ST, r);   if (r !== 32'd0) fail($sformatf("D4.%0d: IRQ_STATUS not cleared", k));
      if (irq)                fail($sformatf("D4.%0d: irq high after reset", k));
      u_src.stall_pct = 0; u_ddr.stall_pct = 0;
      do_transfer(rnd(0, 100) * 8, rnd(0, 100) * 8, 8 * rnd(1, 200), 0, 0, $sformatf("D4.%0d recover", k));
    end

    // ---- R: random transfers --------------------------------------------------
    $display("[R] %0d random transfers", ITER);
    n_rd_err = 0; n_wr_err = 0; n_bytes = 0;
    for (int it = 0; it < ITER; it++) begin
      pick_clocks();
      u_src.stall_pct = pick_stall(); u_ddr.stall_pct = pick_stall();
      len_b = pick_len();
      src_b = pick_addr(len_b); dst_b = pick_addr(len_b);
      inj_r = (rnd(0, 7) == 0); inj_w = (rnd(0, 7) == 0);
      n_rd_err += inj_r; n_wr_err += inj_w; n_bytes += len_b;
      do_transfer(src_b, dst_b, len_b, inj_r, inj_w,
                  $sformatf("R%0d src=%h dst=%h len=%0d", it, src_b, dst_b, len_b));
      if (errors > 20) break;
    end
    $display("       %0d bytes moved, %0d read-error and %0d write-error cases", n_bytes, n_rd_err, n_wr_err);

    // ---- B: back-to-back, never idle ----------------------------------------
    $display("[B] 30 back-to-back transfers");
    u_src.stall_pct = 10; u_ddr.stall_pct = 10;
    for (int k = 0; k < 30; k++)
      do_transfer(rnd(0, 200) * 8, rnd(0, 200) * 8, 8 * rnd(1, 90), 0, 0, $sformatf("B%0d", k));

    if (errors == 0) $display("RESULT: PASS");
    else             $fatal(1, "RESULT: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #2_000_000_000; $fatal(1, "RESULT: GLOBAL TIMEOUT"); end
endmodule
