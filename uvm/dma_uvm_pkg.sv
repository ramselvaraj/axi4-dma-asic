`timescale 1ns/1ps
// UVM environment for the AXI4 DMA (dma_top).
//
//   test -> env -> agent(sequencer, driver, axil monitor) + rd/wr AXI monitors + scoreboard + coverage
//
// The scoreboard is passive: it reconstructs every transfer from what the monitors see on the AXI4-Lite port
// (SRC/DST/LEN/START writes, STATUS reads) and checks the AXI4 master traffic and the final memory contents
// (through a backdoor handle to the two memory models) against that.
package dma_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  localparam int MEM_WORDS = 1 << 14;
  localparam int MEM_BYTES = MEM_WORDS * 8;
  localparam logic [63:0] SENTINEL = 64'hDEAD_BEEF_0BAD_F00D;
  localparam logic [7:0] R_CTRL = 8'h00, R_STATUS = 8'h04, R_SRC = 8'h08, R_DST = 8'h0C, R_LEN = 8'h10,
                         R_IRQ_EN = 8'h14, R_IRQ_ST = 8'h18;

  // ------------------------------------------------------------------ memory backdoor
  virtual class mem_access_base;
    pure virtual function logic [63:0] rd_src(int unsigned i);
    pure virtual function logic [63:0] rd_dst(int unsigned i);
    pure virtual function void wr_src(int unsigned i, logic [63:0] d);
    pure virtual function void wr_dst(int unsigned i, logic [63:0] d);
    static function logic [63:0] pat(int unsigned i);
      return {32'hC0DE0000 ^ 32'(i), ~(32'(i) * 32'd2654435761)};
    endfunction
    function void fill();
      for (int unsigned i = 0; i < MEM_WORDS; i++) begin wr_src(i, pat(i)); wr_dst(i, SENTINEL); end
    endfunction
  endclass

  `include "dma_items.svh"
  `include "dma_monitors.svh"
  `include "dma_agent.svh"
  `include "dma_scoreboard.svh"
  `include "dma_env.svh"
  `include "dma_sequences.svh"
  `include "dma_tests.svh"
endpackage
