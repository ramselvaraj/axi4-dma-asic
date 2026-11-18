`timescale 1ns/1ps
// Interfaces for the UVM testbench: AXI4-Lite control port, the two AXI4 master ports (monitor only),
// and a control/knob interface (reset, clock periods, memory-model stall/error knobs, irq).

interface axil_if (input logic clk, input logic rst_n);
  logic [7:0]  awaddr;  logic awvalid, awready;
  logic [31:0] wdata;   logic [3:0] wstrb; logic wvalid, wready;
  logic [1:0]  bresp;   logic bvalid, bready;
  logic [7:0]  araddr;  logic arvalid, arready;
  logic [31:0] rdata;   logic [1:0] rresp; logic rvalid, rready;

  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output awaddr, awvalid, wdata, wstrb, wvalid, bready, araddr, arvalid, rready;
    input  awready, wready, bresp, bvalid, arready, rdata, rresp, rvalid;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bresp, bvalid, bready,
          araddr, arvalid, arready, rdata, rresp, rvalid, rready;
  endclocking
endinterface

interface axi_rd_if (input logic clk, input logic rst_n);
  logic [31:0] araddr; logic [7:0] arlen; logic arvalid, arready;
  logic rvalid, rready, rlast; logic [63:0] rdata; logic [1:0] rresp;
  clocking mon_cb @(posedge clk);
    default input #1step;
    input araddr, arlen, arvalid, arready, rvalid, rready, rlast, rdata, rresp;
  endclocking
endinterface

interface axi_wr_if (input logic clk, input logic rst_n);
  logic [31:0] awaddr; logic [7:0] awlen; logic awvalid, awready;
  logic wvalid, wready, wlast; logic [63:0] wdata; logic [7:0] wstrb;
  logic bvalid, bready; logic [1:0] bresp;
  clocking mon_cb @(posedge clk);
    default input #1step;
    input awaddr, awlen, awvalid, awready, wvalid, wready, wlast, wdata, wstrb, bvalid, bready, bresp;
  endclocking
endinterface

interface dma_ctl_if;
  logic rst_rd_n = 1'b0, rst_wr_n = 1'b0;
  logic irq;
  real  rd_half = 5.0, wr_half = 3.2;           // clock half periods (ns), changed only while the DMA is idle
  int   stall_rd = 0, stall_wr = 0;             // memory-model stall probability, percent
  bit   rd_err_en = 0, wr_err_en = 0;           // inject SLVERR on one beat address
  int unsigned rd_err_addr = 0, wr_err_addr = 0;
endinterface
