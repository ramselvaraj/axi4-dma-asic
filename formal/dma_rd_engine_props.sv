// Formal properties for dma_rd_engine, attached with `bind` so the RTL is untouched.
// Assumptions are exactly the preconditions the register block guarantees:
//   start only when idle, src/len 8-byte aligned, len non-zero (dma_regs.cfg_bad rejects everything else).
module dma_rd_engine_props import dma_pkg::*; (
  input logic        clk, rst_n,
  input logic        start,
  input logic [31:0] src, len,
  input logic [31:0] araddr,
  input logic [7:0]  arlen,
  input logic        arvalid, arready,
  input logic        ar_busy,
  input logic [31:0] cur, rem
);
  logic past_valid = 1'b0;
  always @(posedge clk) past_valid <= 1'b1;
  always @* if (!past_valid) assume (!rst_n);       // start in reset

  // ---- assumptions (environment contract)
  always @(posedge clk) if (past_valid) begin
    if (start) begin
      assume (src[2:0] == 3'd0);
      assume (len[2:0] == 3'd0);
      assume (len != 32'd0);
      assume (!ar_busy && !arvalid);                  // START is ignored while busy, so the engine is idle
    end
  end

  // ---- invariants (checked every cycle once out of reset)
  always @(posedge clk) if (past_valid && rst_n) begin
    // P1: an issued burst never crosses a 4 KiB boundary
    if (arvalid) assert ({20'd0, araddr[11:0]} + (32'(arlen) + 32'd1) * 32'd8 <= 32'd4096);
    // P2: burst length is 1..MAX_BEATS beats
    if (arvalid) assert (arlen <= 8'(MAX_BEATS - 1));
    // P3: addresses stay 8-byte aligned
    if (arvalid) assert (araddr[2:0] == 3'd0);
    // P4: the engine only carries 8-byte-granular state and never runs dry while it still has work to issue
    assert (cur[2:0] == 3'd0);
    assert (rem[2:0] == 3'd0);
    if (ar_busy) assert (rem != 32'd0);
  end

`ifdef ACCOUNTING
  // ---- P5: byte accounting (bounded check only: 32-bit modular accounting does not converge in k-induction/PDR). Ghost copies of the programmed transfer; every issued burst moves `cur` and `rem` together,
  // so issued + remaining == len at all times, and when the engine stops issuing nothing is left over.
  logic [31:0] g_src = 32'd0, g_len = 32'd0;
  logic        g_busy_q = 1'b0;
  always @(posedge clk) begin
    g_busy_q <= ar_busy;
    if (start) begin g_src <= src; g_len <= len; end
  end
  always @(posedge clk) if (past_valid && rst_n) begin
    if (ar_busy) assert (rem + (cur - g_src) == g_len);
    if (g_busy_q && !ar_busy && !start) assert (rem == 32'd0 && (cur - g_src) == g_len);
  end

`endif

  // ---- cover: the properties above must not hold vacuously
  logic ar_busy_q = 1'b0;
  always @(posedge clk) ar_busy_q <= ar_busy;
  always @(posedge clk) if (past_valid && rst_n) begin
    cover (arvalid);                                                  // a burst is issued
    cover (arvalid && arlen == 8'(MAX_BEATS - 1));                    // a full-length burst
    cover (arvalid && araddr[11:0] != 12'd0 && arlen < 8'(MAX_BEATS - 1) && ar_busy);   // a burst shortened by the 4 KiB page edge
    cover (ar_busy_q && !ar_busy);                                    // a transfer finishes issuing
  end
endmodule

bind dma_rd_engine dma_rd_engine_props props (.*);
