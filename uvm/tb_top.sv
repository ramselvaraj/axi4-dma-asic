`timescale 1ns/1ps
// UVM top: DUT + two behavioural AXI4 memories (the same models the plain testbenches use), interfaces, clocks.
module tb_top;
  import uvm_pkg::*;
  import dma_uvm_pkg::*;
  `include "uvm_macros.svh"

  parameter int FIFO_AW = 5;

  logic clk_rd = 0, clk_wr = 0;
  dma_ctl_if ctl ();
  initial forever #(ctl.rd_half) clk_rd = ~clk_rd;
  initial forever #(ctl.wr_half) clk_wr = ~clk_wr;

  // reset: release rd domain then wr domain
  initial begin
    ctl.rst_rd_n = 0; ctl.rst_wr_n = 0;
    repeat (8) @(posedge clk_rd);
    ctl.rst_rd_n = 1;
    repeat (4) @(posedge clk_wr);
    ctl.rst_wr_n = 1;
  end

  axil_if   axil (clk_rd, ctl.rst_rd_n);
  axi_rd_if rdif (clk_rd, ctl.rst_rd_n);
  axi_wr_if wrif (clk_wr, ctl.rst_wr_n);

  logic [31:0] m_araddr; logic [7:0] m_arlen; logic m_arvalid, m_arready;
  logic m_rvalid, m_rready, m_rlast; logic [63:0] m_rdata; logic [1:0] m_rresp;
  logic [31:0] m_awaddr; logic [7:0] m_awlen; logic m_awvalid, m_awready;
  logic m_wvalid, m_wready, m_wlast; logic [63:0] m_wdata; logic [7:0] m_wstrb;
  logic m_bvalid, m_bready; logic [1:0] m_bresp;
  logic irq;

  dma_top #(.FIFO_AW(FIFO_AW)) dut (
    .clk_rd, .rst_rd_n(ctl.rst_rd_n), .clk_wr, .rst_wr_n(ctl.rst_wr_n),
    .s_awaddr(axil.awaddr), .s_awvalid(axil.awvalid), .s_awready(axil.awready),
    .s_wdata(axil.wdata), .s_wstrb(axil.wstrb), .s_wvalid(axil.wvalid), .s_wready(axil.wready),
    .s_bresp(axil.bresp), .s_bvalid(axil.bvalid), .s_bready(axil.bready),
    .s_araddr(axil.araddr), .s_arvalid(axil.arvalid), .s_arready(axil.arready),
    .s_rdata(axil.rdata), .s_rresp(axil.rresp), .s_rvalid(axil.rvalid), .s_rready(axil.rready),
    .m_araddr, .m_arlen, .m_arvalid, .m_arready, .m_rvalid, .m_rready, .m_rdata, .m_rresp, .m_rlast,
    .m_awaddr, .m_awlen, .m_awvalid, .m_awready, .m_wvalid, .m_wready, .m_wdata, .m_wstrb, .m_wlast,
    .m_bvalid, .m_bready, .m_bresp, .irq
  );
  assign ctl.irq = irq;

  axi4_mem_model #(.DDR_MODE(0), .SIMPLE_LAT(2)) u_src (
    .clk(clk_rd), .rst_n(ctl.rst_rd_n),
    .araddr(m_araddr), .arlen(m_arlen), .arvalid(m_arvalid), .arready(m_arready),
    .rvalid(m_rvalid), .rready(m_rready), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast),
    .awaddr('0), .awlen('0), .awvalid(1'b0), .awready(),
    .wvalid(1'b0), .wready(), .wdata('0), .wstrb('0), .wlast(1'b0),
    .bvalid(), .bready(1'b1), .bresp()
  );
  axi4_mem_model #(.DDR_MODE(1), .TREFI(150), .TRFC(20)) u_ddr (
    .clk(clk_wr), .rst_n(ctl.rst_wr_n),
    .araddr('0), .arlen('0), .arvalid(1'b0), .arready(),
    .rvalid(), .rready(1'b1), .rdata(), .rresp(), .rlast(),
    .awaddr(m_awaddr), .awlen(m_awlen), .awvalid(m_awvalid), .awready(m_awready),
    .wvalid(m_wvalid), .wready(m_wready), .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast),
    .bvalid(m_bvalid), .bready(m_bready), .bresp(m_bresp)
  );

  // FIFO protocol checks (reported through UVM so they count as test errors)
  always @(posedge clk_rd) if (ctl.rst_rd_n && dut.fifo_winc && dut.fifo_wfull) uvm_report_error("FIFO", "write into a full async FIFO (overflow)");
  always @(posedge clk_wr) if (ctl.rst_wr_n && dut.fifo_rinc && dut.fifo_rempty) uvm_report_error("FIFO", "read from an empty async FIFO (underflow)");

  // knobs -> memory models
  always @(ctl.stall_rd)    u_src.stall_pct = ctl.stall_rd;
  always @(ctl.stall_wr)    u_ddr.stall_pct = ctl.stall_wr;
  always @(ctl.rd_err_en or ctl.rd_err_addr) begin u_src.err_en = ctl.rd_err_en; u_src.err_lo = ctl.rd_err_addr; u_src.err_hi = ctl.rd_err_addr; end
  always @(ctl.wr_err_en or ctl.wr_err_addr) begin u_ddr.err_en = ctl.wr_err_en; u_ddr.err_lo = ctl.wr_err_addr; u_ddr.err_hi = ctl.wr_err_addr; end

  // monitor views of the master ports
  assign rdif.araddr = m_araddr; assign rdif.arlen = m_arlen; assign rdif.arvalid = m_arvalid; assign rdif.arready = m_arready;
  assign rdif.rvalid = m_rvalid; assign rdif.rready = m_rready; assign rdif.rlast = m_rlast;
  assign rdif.rdata = m_rdata;   assign rdif.rresp = m_rresp;
  assign wrif.awaddr = m_awaddr; assign wrif.awlen = m_awlen; assign wrif.awvalid = m_awvalid; assign wrif.awready = m_awready;
  assign wrif.wvalid = m_wvalid; assign wrif.wready = m_wready; assign wrif.wlast = m_wlast;
  assign wrif.wdata = m_wdata;   assign wrif.wstrb = m_wstrb;
  assign wrif.bvalid = m_bvalid; assign wrif.bready = m_bready; assign wrif.bresp = m_bresp;

  // backdoor into the memory models
  class mem_access_impl extends mem_access_base;
    virtual function logic [63:0] rd_src(int unsigned i); return u_src.mem[i]; endfunction
    virtual function logic [63:0] rd_dst(int unsigned i); return u_ddr.mem[i]; endfunction
    virtual function void wr_src(int unsigned i, logic [63:0] d); u_src.mem[i] = d; endfunction
    virtual function void wr_dst(int unsigned i, logic [63:0] d); u_ddr.mem[i] = d; endfunction
  endclass

  initial begin
    mem_access_impl m = new();
    uvm_config_db#(virtual axil_if)::set(null, "*", "axil_vif", axil);
    uvm_config_db#(virtual axi_rd_if)::set(null, "*", "rd_vif", rdif);
    uvm_config_db#(virtual axi_wr_if)::set(null, "*", "wr_vif", wrif);
    uvm_config_db#(virtual dma_ctl_if)::set(null, "*", "ctl_vif", ctl);
    uvm_config_db#(mem_access_base)::set(null, "*", "mem", m);
    run_test();
  end
endmodule
