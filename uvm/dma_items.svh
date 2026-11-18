// Transaction types ---------------------------------------------------------------------------------------------
typedef enum {K_VALID, K_ZERO_LEN, K_LEN_UNALIGNED, K_SRC_UNALIGNED, K_DST_UNALIGNED,
              K_SRC_OVERFLOW, K_DST_OVERFLOW} dma_kind_e;

// One DMA programming + run request (sequence item).
class dma_item extends uvm_sequence_item;
  rand dma_kind_e   kind;
  bit [31:0]        src, dst, len;           // derived from the rand picks below in post_randomize()
  rand int unsigned len_w, src_pick, dst_pick;   // length in 8-byte words, raw address picks
  rand bit [2:0]    tail;                        // 1..7 extra bytes for the unaligned kinds
  rand bit          hug_src, hug_dst;        // place the address just below a 4 KiB boundary
  rand bit          inj_rd_err, inj_wr_err;  // SLVERR on one beat of the transfer
  rand int unsigned rd_err_beat, wr_err_beat;
  rand int unsigned stall_rd, stall_wr;      // memory stall probability (percent)
  rand bit [1:0]    rd_clk;
  rand bit [2:0]    wr_clk;
  rand bit [1:0]    irq_en;                      // IRQ_EN value programmed for this transfer (0 = poll STATUS only)
  rand bit          poke;                        // while busy: write new SRC/DST/LEN and a second START (must be ignored)
  rand bit          do_reset;                    // reset both domains in the middle of the transfer
  rand int unsigned reset_delay;
  bit               valid_only = 1, inj_en = 0;   // sequence-level mode switches (not randomized)

  `uvm_object_utils(dma_item)
  function new(string name = "dma_item"); super.new(name); endfunction

  constraint c_kind  { soft kind dist {K_VALID := 80, K_ZERO_LEN := 3, K_LEN_UNALIGNED := 3, K_SRC_UNALIGNED := 3,
                                       K_DST_UNALIGNED := 3, K_SRC_OVERFLOW := 4, K_DST_OVERFLOW := 4}; }
  constraint c_stall { stall_rd dist {0 := 3, 15 := 1, 40 := 1, 70 := 1, 92 := 1};
                       stall_wr dist {0 := 3, 15 := 1, 40 := 1, 70 := 1, 92 := 1}; }
  constraint c_mode  { if (valid_only) kind == K_VALID; if (!inj_en) { inj_rd_err == 0; inj_wr_err == 0; } }
  constraint c_misc  { irq_en dist {3 := 6, 0 := 2, 1 := 1, 2 := 1}; poke dist {0 := 8, 1 := 2}; do_reset dist {0 := 19, 1 := 1};
                       reset_delay inside {[3:600]}; }
  constraint c_clk   { wr_clk < 5; }
  constraint c_hug   { hug_src dist {0 := 2, 1 := 1}; hug_dst dist {0 := 2, 1 := 1}; }

  // valid geometry: aligned, inside the 128 KiB memories
  constraint c_len   { len_w dist {1 := 10, [2:16] :/ 25, [17:128] :/ 40, [129:1024] :/ 25}; tail != 0; }

  // Addresses are derived procedurally so the constraint set stays trivial for every simulator's solver.
  function void post_randomize();
    int unsigned nbytes = len_w * 8;
    int unsigned maxa;
    len = nbytes; src = 0; dst = 0;
    case (kind)
      K_ZERO_LEN:       len = 0;
      K_LEN_UNALIGNED:  len = nbytes + tail;
      K_SRC_OVERFLOW, K_DST_OVERFLOW: len = 4112 + 8 * (len_w % 2000);
      default: ;
    endcase
    maxa = (MEM_BYTES - nbytes) / 8;                       // highest 8-byte slot that keeps the transfer inside memory
    src = 8 * (src_pick % (maxa + 1));
    dst = 8 * (dst_pick % (maxa + 1));
    if (kind == K_VALID) begin
      if (hug_src && nbytes + 8 * 20 <= MEM_BYTES) src = pick_edge(src_pick, nbytes);
      if (hug_dst && nbytes + 8 * 20 <= MEM_BYTES) dst = pick_edge(dst_pick, nbytes);
    end
    if (kind == K_SRC_UNALIGNED) src = src | tail;
    if (kind == K_DST_UNALIGNED) dst = dst | tail;
    if (kind == K_SRC_OVERFLOW)  src = 32'hFFFF_FFF8 - 8 * (src_pick % 512);   // src + len wraps past 4 GiB
    if (kind == K_DST_OVERFLOW)  dst = 32'hFFFF_FFF8 - 8 * (dst_pick % 512);
    // poking a running transfer needs one that is certainly still busy; a reset needs real work in flight
    if (kind != K_VALID || len < 2048) poke = 0;
    if (kind != K_VALID || len < 512 || poke) do_reset = 0;
  endfunction

  // an aligned address 8..160 bytes below a 4 KiB boundary that still leaves the transfer inside memory
  function int unsigned pick_edge(int unsigned pick, int unsigned nbytes);
    int unsigned page, a;
    page = 1 + pick % (MEM_BYTES / 4096 - 1);
    a = page * 4096 - 8 * (1 + (pick >> 8) % 20);
    if (a + nbytes > MEM_BYTES) a = MEM_BYTES - nbytes;
    return a & ~32'h7;
  endfunction

  constraint c_err   { if (kind != K_VALID) { inj_rd_err == 0; inj_wr_err == 0; }
                       inj_rd_err dist {0 := 9, 1 := 1}; inj_wr_err dist {0 := 9, 1 := 1};
                       rd_err_beat < len_w; wr_err_beat < len_w; }

  function string convert2string();
    return $sformatf("%s src=%08h dst=%08h len=%0d rd_err=%0b wr_err=%0b stall=%0d/%0d clk=%0d/%0d irq_en=%0d poke=%0b reset=%0b",
                     kind.name(), src, dst, len, inj_rd_err, inj_wr_err, stall_rd, stall_wr, rd_clk, wr_clk, irq_en, poke, do_reset);
  endfunction
endclass

// What the monitors see on the AXI4-Lite port.
class dma_reg_txn extends uvm_sequence_item;
  bit        is_write;
  bit [7:0]  addr;
  bit [31:0] data;
  `uvm_object_utils(dma_reg_txn)
  function new(string name = "dma_reg_txn"); super.new(name); endfunction
endclass

// One completed AXI4 burst on a master port.
class dma_burst extends uvm_sequence_item;
  bit        is_write;
  bit [31:0] addr;
  int        len;       // arlen/awlen (beats - 1)
  int        beats;     // beats actually transferred
  `uvm_object_utils(dma_burst)
  function new(string name = "dma_burst"); super.new(name); endfunction
endclass

// Summary of one finished transfer, published by the scoreboard for coverage.
class dma_xfer_rec extends uvm_sequence_item;
  bit [31:0] src, dst, len;
  bit        cfg_bad, rd_err, wr_err;
  int        n_rd_bursts, n_wr_bursts, max_rd_beats, max_wr_beats;
  int        stall_rd, stall_wr;
  bit [1:0]  irq_en;
  `uvm_object_utils(dma_xfer_rec)
  function new(string name = "dma_xfer_rec"); super.new(name); endfunction
endclass
