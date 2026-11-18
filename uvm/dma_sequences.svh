// Sequences ---------------------------------------------------------------------------------------------------
class dma_base_seq extends uvm_sequence #(dma_item);
  `uvm_object_utils(dma_base_seq)
  function new(string name = "dma_base_seq"); super.new(name); endfunction
endclass

// N random transfers; `valid_only` restricts to legal configurations, `inj` enables error injection.
class dma_rand_seq extends dma_base_seq;
  `uvm_object_utils(dma_rand_seq)
  int unsigned n = 50;
  bit valid_only = 1, inj = 0;
  function new(string name = "dma_rand_seq"); super.new(name); endfunction
  task body();
    dma_item it;
    repeat (n) begin
      it = dma_item::type_id::create("it");
      it.valid_only = valid_only; it.inj_en = inj;
      start_item(it);
      if (!it.randomize()) `uvm_fatal("RAND", "randomize failed")
      finish_item(it);
    end
  endtask
endclass

// Hand-picked corner cases.
class dma_corner_seq extends dma_base_seq;
  `uvm_object_utils(dma_corner_seq)
  function new(string name = "dma_corner_seq"); super.new(name); endfunction
  // Directed items are filled in directly (no randomization): every field is specified.
  task one(bit [31:0] s, bit [31:0] d, bit [31:0] l, dma_kind_e k = K_VALID);
    dma_item it = dma_item::type_id::create("it");
    start_item(it);
    it.kind = k; it.src = s; it.dst = d; it.len = l;
    it.hug_src = 0; it.hug_dst = 0; it.inj_rd_err = 0; it.inj_wr_err = 0; it.rd_err_beat = 0; it.wr_err_beat = 0;
    it.stall_rd = 0; it.stall_wr = 0; it.rd_clk = 1; it.wr_clk = 1;
    it.irq_en = 2'b11; it.poke = 0; it.do_reset = 0; it.reset_delay = 0;
    finish_item(it);
  endtask
  task body();
    one(32'h0,      32'h0,      8);            // single beat
    one(32'h1000,   32'h2000,   128);          // exactly one full burst
    one(32'h1000,   32'h2000,   136);          // one burst plus one beat
    one(32'hFF8,    32'h1FF8,   16);           // both sides straddle a 4 KiB boundary
    one(32'hFC0,    32'h3000,   8192);         // long, read side crosses pages
    one(32'h0,      32'h1000,   8192);         // aligned multi-page
    one(MEM_BYTES - 8192, MEM_BYTES - 8192, 8192);   // top of memory
    one(32'h0,      32'h0,      0,  K_ZERO_LEN);
    one(32'h100,    32'h200,    12, K_LEN_UNALIGNED);
    one(32'h104,    32'h200,    64, K_SRC_UNALIGNED);
    one(32'h100,    32'h202,    64, K_DST_UNALIGNED);
    one(32'hFFFF_FFF8, 32'h200, 16, K_SRC_OVERFLOW);   // finding D1: used to wrap to address 0
    one(32'h100,    32'hFFFF_FFF8, 16, K_DST_OVERFLOW);
  endtask
endclass
