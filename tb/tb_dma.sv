`timescale 1ns/1ps
module tb_dma;
  import dma_pkg::*;

  logic clk_rd = 0, clk_wr = 0, rst_rd_n = 0, rst_wr_n = 0;
  always #5.0  clk_rd = ~clk_rd;   // 100 MHz system / SRAM clock
  always #3.2  clk_wr = ~clk_wr;   // ~156 MHz DDR user clock

  // AXI4-Lite
  logic [7:0] awaddr, araddr_l; logic awvalid, wvalid, arvalid_l, bready = 1, rready_l = 1;
  logic [31:0] wdata_l, rdata_l; logic awready, wready, bvalid, arready_l, rvalid_l;
  logic [1:0] bresp_l, rresp_l;
  // read master <-> source SRAM
  logic [31:0] m_araddr; logic [7:0] m_arlen; logic m_arvalid, m_arready;
  logic m_rvalid, m_rready, m_rlast; logic [63:0] m_rdata; logic [1:0] m_rresp;
  // write master <-> DDR
  logic [31:0] m_awaddr; logic [7:0] m_awlen; logic m_awvalid, m_awready;
  logic m_wvalid, m_wready, m_wlast; logic [63:0] m_wdata; logic [7:0] m_wstrb;
  logic m_bvalid, m_bready; logic [1:0] m_bresp;
  logic irq;

  dma_top dut (
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

  axi4_mem_model #(.DDR_MODE(1)) u_ddr (
    .clk(clk_wr), .rst_n(rst_wr_n),
    .araddr('0), .arlen('0), .arvalid(1'b0), .arready(),
    .rvalid(), .rready(1'b1), .rdata(), .rresp(), .rlast(),
    .awaddr(m_awaddr), .awlen(m_awlen), .awvalid(m_awvalid), .awready(m_awready),
    .wvalid(m_wvalid), .wready(m_wready), .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast),
    .bvalid(m_bvalid), .bready(m_bready), .bresp(m_bresp)
  );

  // AXI-Lite helpers (drive/sample on clk_rd; NBA drive, active-region sample)
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

  int errors = 0;
  task automatic check(input string what, input bit ok);
    if (!ok) begin errors++; $display("  FAIL: %s", what); end
    else $display("  ok:   %s", what);
  endtask

  function automatic [63:0] pat(input int i);
    return {32'hC0DE0000 ^ 32'(i), ~32'(i * 7)};
  endfunction

  task automatic fill_src();
    for (int i = 0; i < (1 << 14); i++) u_src.mem[i] = pat(i);
    for (int i = 0; i < (1 << 14); i++) u_ddr.mem[i] = 64'hDEAD_DEAD_DEAD_DEAD;
  endtask

  function automatic int count_mismatch(input int src_b, input int dst_b, input int len_b);
    int bad = 0;
    for (int i = 0; i < len_b / 8; i++)
      if (u_ddr.mem[dst_b/8 + i] !== u_src.mem[src_b/8 + i]) bad++;
    return bad;
  endfunction

  // returns elapsed rd-clk cycles until irq
  task automatic run_dma(input int src_b, input int dst_b, input int len_b, output int cycles);
    cycles = 0;
    axil_write(SRC, src_b); axil_write(DST, dst_b); axil_write(LEN, len_b);
    axil_write(CTRL, 1);
    while (!irq && cycles < 200000) begin @(posedge clk_rd); cycles++; end
  endtask

  logic [31:0] r;
  int cyc, bad, ref0;

  initial begin
    $dumpfile("tb_dma.vcd"); $dumpvars(0, tb_dma);
    awvalid = 0; wvalid = 0; arvalid_l = 0; awaddr = 0; wdata_l = 0; araddr_l = 0;
    fill_src();
    repeat (5) @(posedge clk_rd);
    rst_rd_n = 1; rst_wr_n = 1;
    repeat (5) @(posedge clk_rd);

    $display("[T1] 1KB aligned copy, IRQ on done");
    axil_write(IRQ_EN, 2'b11);
    run_dma(32'h100, 32'h2000, 1024, cyc);
    check("irq asserted", irq);
    axil_read(STATUS, r);   check("STATUS = done", r[1:0] == 2'b10);
    axil_read(IRQ_ST, r);   check("IRQ_STATUS.done set, err clear", r[1:0] == 2'b01);
    check("data matches", count_mismatch(32'h100, 32'h2000, 1024) == 0);
    $display("       %0d cycles for 1024 B", cyc);
    axil_write(IRQ_ST, 2'b01);
    repeat (2) @(posedge clk_rd);
    check("irq cleared by W1C", !irq);

    $display("[T2] crosses 4KB boundary on both sides, 4104 B");
    run_dma(32'h0FF8, 32'h3FF8, 4104, cyc);
    check("irq asserted", irq);
    check("data matches", count_mismatch(32'h0FF8, 32'h3FF8, 4104) == 0);
    axil_write(IRQ_ST, 2'b11);

    $display("[T3] bad config (len not multiple of 8) -> error IRQ, no start");
    axil_write(SRC, 32'h0); axil_write(DST, 32'h8000); axil_write(LEN, 12);
    axil_write(CTRL, 1);
    repeat (4) @(posedge clk_rd);
    check("irq asserted", irq);
    axil_read(STATUS, r);  check("STATUS.cfg_err set, not busy", r[4] && !r[0]);
    axil_read(IRQ_ST, r);  check("IRQ_STATUS.err set", r[1]);
    axil_write(IRQ_ST, 2'b11);

    $display("[T4] interrupt masked: status sets but irq pin stays low");
    axil_write(IRQ_EN, 2'b00);
    axil_write(SRC, 32'h0); axil_write(DST, 32'h4000); axil_write(LEN, 256);
    axil_write(CTRL, 1);
    r = 1;
    while (r[0]) axil_read(STATUS, r);    // poll busy
    axil_read(IRQ_ST, r);
    check("IRQ_STATUS.done set while masked", r[0]);
    check("irq pin low while masked", !irq);
    axil_write(IRQ_ST, 2'b11);
    axil_write(IRQ_EN, 2'b11);

    $display("[T5] 32KB transfer through DDR model (row hits/misses/refresh)");
    ref0 = u_ddr.refreshes;
    run_dma(32'h0, 32'h10000, 32768, cyc);
    check("irq asserted", irq);
    check("data matches", count_mismatch(32'h0, 32'h10000, 32768) == 0);
    $display("       %0d rd-clk cycles for 32768 B  (%0.2f B/cycle @100MHz-side)",
             cyc, 32768.0 / cyc);
    $display("       DDR: %0d bursts, row hits %0d, misses %0d, refreshes %0d",
             u_ddr.wr_bursts, u_ddr.row_hits, u_ddr.row_misses, u_ddr.refreshes - ref0);
    axil_write(IRQ_ST, 2'b11);

    if (errors == 0) $display("\nALL TESTS PASSED");
    else             $display("\n%0d CHECK(S) FAILED", errors);
    $finish;
  end

  initial begin #20_000_000; $display("TIMEOUT"); $finish; end
endmodule
