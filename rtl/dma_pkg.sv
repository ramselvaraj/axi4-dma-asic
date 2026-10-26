package dma_pkg;
  localparam int DW        = 64;
  localparam int MAX_BEATS = 16;   // AXI4 INCR burst cap used by the engine

  // Largest burst that stays within MAX_BEATS, the bytes remaining, and the
  // current 4KB page (AXI bursts must not cross a 4KB boundary).
  function automatic logic [4:0] calc_beats(input logic [31:0] addr,
                                            input logic [31:0] rem);
    logic [31:0] to_4k, rem_beats, page_beats, m;
    to_4k      = 32'd4096 - {20'd0, addr[11:0]};
    rem_beats  = rem >> 3;
    page_beats = to_4k >> 3;
    m = MAX_BEATS;
    if (rem_beats  < m) m = rem_beats;
    if (page_beats < m) m = page_beats;
    return m[4:0];
  endfunction
endpackage
