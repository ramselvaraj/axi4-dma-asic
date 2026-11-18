// Probe: nothing in dma_regs checks that SRC + LEN stays inside the 32-bit address space.
// No single burst can wrap (bursts stop at 4 KiB pages and 4 GiB is a page boundary), but a *transfer* whose
// SRC + LEN exceeds 2^32 keeps issuing bursts after cur wraps to 0. Under the register block's contract only
// (aligned, non-zero LEN), can the engine be in the state "bytes still to read extend past 4 GiB"?
// Before the D1 fix this failed (counterexample src=0xFFFFFFF8). With the register block's overflow check
// assumed (dma_regs cfg_bad) it must hold.
module dma_rd_engine_wrap import dma_pkg::*; (
  input logic        clk, rst_n, start,
  input logic [31:0] src, len, cur, rem,
  input logic        arvalid, ar_busy
);
  logic past_valid = 1'b0;
  always @(posedge clk) past_valid <= 1'b1;
  always @* if (!past_valid) assume (!rst_n);
  always @(posedge clk) if (past_valid && start) begin
    assume (src[2:0] == 3'd0); assume (len[2:0] == 3'd0); assume (len != 32'd0); assume (!ar_busy && !arvalid);
    assume ({1'b0, src} + {1'b0, len} <= 33'h1_0000_0000);  // D1 fix: dma_regs cfg_bad rejects overflow
  end
  always @(posedge clk) if (past_valid && rst_n && ar_busy)
    assert ({1'b0, cur} + {1'b0, rem} <= 33'h1_0000_0000);
endmodule
bind dma_rd_engine dma_rd_engine_wrap wrapprobe (.*);
