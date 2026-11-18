// Formal properties for dma_wr_engine, attached with `bind` (RTL untouched).
// Environment contract assumed (what dma_regs / the AXI slave / the async FIFO guarantee):
//   start only when idle, dst/len 8-byte aligned and len non-zero; the FIFO never retracts data it has offered.
module dma_wr_engine_props import dma_pkg::*; (
  input logic        clk, rst_n, start,
  input logic [31:0] dst, len, awaddr,
  input logic [7:0]  awlen,
  input logic        awvalid, awready, wvalid, wready, wlast, bvalid, bready, fifo_rempty, fifo_rinc, done_pulse,
  input logic [2:0]  st,
  input logic [31:0] cur, rem,
  input logic [4:0]  cnt
);
  localparam logic [2:0] S_IDLE = 3'd0, S_ISSUE = 3'd1, S_AW = 3'd2, S_DATA = 3'd3, S_RESP = 3'd4, S_DONE = 3'd5;
  logic past_valid = 1'b0;
  always @(posedge clk) past_valid <= 1'b1;
  always @* if (!past_valid) assume (!rst_n);

  logic w_stall_q = 1'b0;                        // previous cycle: W offered but not accepted
  always @(posedge clk) w_stall_q <= wvalid && !wready;

  // ---- assumptions
  always @(posedge clk) if (past_valid) begin
    if (start) begin
      assume (dst[2:0] == 3'd0); assume (len[2:0] == 3'd0); assume (len != 32'd0);
      assume (st == S_IDLE);                      // START is ignored while busy
    end
    if (w_stall_q) assume (!fifo_rempty);         // the FIFO does not retract an offered word until it is popped
  end

  // ---- invariants
  always @(posedge clk) if (past_valid && rst_n) begin
    if (awvalid) begin
      assert ({20'd0, awaddr[11:0]} + (32'(awlen) + 32'd1) * 32'd8 <= 32'd4096);   // 4 KiB rule
      assert (awlen <= 8'(MAX_BEATS - 1));                                         // 1..16 beats
      assert (awaddr[2:0] == 3'd0);
    end
    assert (cur[2:0] == 3'd0); assert (rem[2:0] == 3'd0);
    assert (st <= S_DONE);                                                         // no illegal encoding
    assert (!bready || st == S_RESP);                                              // B only accepted while waiting for it
    assert (!wvalid || st == S_DATA);                                              // W only while a burst is open
    assert (awvalid == (st == S_AW));                                              // AW valid exactly while the FSM waits for it
    if (st == S_ISSUE) assert (rem != 32'd0);                                      // there is always something left to issue
    if (st == S_AW || st == S_DATA) assert (cnt != 5'd0);                           // an open burst always has beats left
    assert (cnt <= 5'(MAX_BEATS));
    if (st == S_AW) assert (cnt == 5'(awlen) + 5'd1);                               // the counter mirrors AWLEN
    if (wvalid && wlast) assert (cnt == 5'd1);                                      // WLAST exactly on the final beat
    if (done_pulse) assert (st == S_IDLE);                                          // done only after returning to idle
  end

  // ---- AXI handshake stability (outputs)
  logic aw_stall_q = 1'b0; logic [31:0] aw_addr_q = 32'd0; logic [7:0] aw_len_q = 8'd0;
  always @(posedge clk) begin aw_stall_q <= awvalid && !awready; aw_addr_q <= awaddr; aw_len_q <= awlen; end
  always @(posedge clk) if (past_valid && rst_n) begin
    if (aw_stall_q) assert (awvalid && awaddr == aw_addr_q && awlen == aw_len_q);   // AW held until accepted
    if (w_stall_q)  assert (wvalid);                                                 // W held until accepted
  end

`ifdef ACCOUNTING
  // ---- beats per burst and bytes per transfer (bounded check only; see the read-engine note)
  logic [31:0] g_dst = 32'd0, g_len = 32'd0; logic [4:0] g_beats = 5'd0; logic [7:0] g_sent = 8'd0;
  always @(posedge clk) begin
    if (start) begin g_dst <= dst; g_len <= len; end
    if (st == S_ISSUE) g_sent <= 8'd0; else if (wvalid && wready) g_sent <= g_sent + 8'd1;
  end
  always @(posedge clk) if (past_valid && rst_n) begin
    if (st != S_IDLE && st != S_DONE) assert (rem + (cur - g_dst) == g_len);
    if (wvalid && wready && wlast) assert (g_sent == awlen);                         // awlen+1 beats were sent
    if (st == S_DONE) assert (rem == 32'd0);                                          // all bytes accounted before done
  end
`endif

  always @(posedge clk) if (past_valid && rst_n) begin
    cover (awvalid);
    cover (wvalid && wready && wlast);
    cover (done_pulse);
    cover (awvalid && awlen == 8'(MAX_BEATS - 1));
  end
endmodule
bind dma_wr_engine dma_wr_engine_props props (.*, .st(3'(st)));
