// AXI4 DMA: AXI4-Lite control + IRQ, AXI4 read master (clk_rd) -> async FIFO
// -> AXI4 write master (clk_wr). Typical use: clk_rd = SoC/SRAM clock,
// clk_wr = DDR controller user clock.
module dma_top import dma_pkg::*; #(
  parameter int FIFO_AW = 5
) (
  input  logic clk_rd, rst_rd_n,
  input  logic clk_wr, rst_wr_n,

  // AXI4-Lite slave (clk_rd)
  input  logic [7:0]  s_awaddr,  input  logic s_awvalid, output logic s_awready,
  input  logic [31:0] s_wdata,   input  logic [3:0] s_wstrb,
  input  logic        s_wvalid,  output logic s_wready,
  output logic [1:0]  s_bresp,   output logic s_bvalid,  input  logic s_bready,
  input  logic [7:0]  s_araddr,  input  logic s_arvalid, output logic s_arready,
  output logic [31:0] s_rdata,   output logic [1:0] s_rresp,
  output logic        s_rvalid,  input  logic s_rready,

  // AXI4 read master (clk_rd): AR + R
  output logic [31:0] m_araddr,  output logic [7:0] m_arlen,
  output logic        m_arvalid, input  logic m_arready,
  input  logic        m_rvalid,  output logic m_rready,
  input  logic [DW-1:0] m_rdata, input  logic [1:0] m_rresp, input logic m_rlast,

  // AXI4 write master (clk_wr): AW + W + B
  output logic [31:0] m_awaddr,  output logic [7:0] m_awlen,
  output logic        m_awvalid, input  logic m_awready,
  output logic        m_wvalid,  input  logic m_wready,
  output logic [DW-1:0] m_wdata, output logic [DW/8-1:0] m_wstrb, output logic m_wlast,
  input  logic        m_bvalid,  output logic m_bready, input logic [1:0] m_bresp,

  output logic irq
);
  logic [31:0] src_addr, dst_addr, len;
  logic start, start_wr, wr_done, done_rd, done_rd_d;
  logic rd_err, wr_err, wr_err_s1, wr_err_s2;

  logic fifo_wfull, fifo_rempty, fifo_winc, fifo_rinc;
  logic [DW-1:0] fifo_wdata, fifo_rdata;

  dma_regs u_regs (
    .clk(clk_rd), .rst_n(rst_rd_n),
    .s_awaddr, .s_awvalid, .s_awready, .s_wdata, .s_wstrb, .s_wvalid, .s_wready,
    .s_bresp, .s_bvalid, .s_bready, .s_araddr, .s_arvalid, .s_arready,
    .s_rdata, .s_rresp, .s_rvalid, .s_rready,
    .src_addr, .dst_addr, .len, .start,
    .done_pulse(done_rd_d), .rd_err, .wr_err(wr_err_s2), .irq
  );

  // SRC/DST/LEN are quasi-static (locked by the register block while busy).
  cdc_pulse u_start_x (.src_clk(clk_rd), .src_rst_n(rst_rd_n), .src_pulse(start),
                       .dst_clk(clk_wr), .dst_rst_n(rst_wr_n), .dst_pulse(start_wr));
  cdc_pulse u_done_x  (.src_clk(clk_wr), .src_rst_n(rst_wr_n), .src_pulse(wr_done),
                       .dst_clk(clk_rd), .dst_rst_n(rst_rd_n), .dst_pulse(done_rd));

  // wr_err is stable well before the done toggle; delay done by one cycle.
  always_ff @(posedge clk_rd or negedge rst_rd_n)
    if (!rst_rd_n) begin wr_err_s1 <= 1'b0; wr_err_s2 <= 1'b0; done_rd_d <= 1'b0; end
    else begin wr_err_s1 <= wr_err; wr_err_s2 <= wr_err_s1; done_rd_d <= done_rd; end

  dma_rd_engine u_rd (
    .clk(clk_rd), .rst_n(rst_rd_n), .start, .src(src_addr), .len,
    .araddr(m_araddr), .arlen(m_arlen), .arvalid(m_arvalid), .arready(m_arready),
    .rvalid(m_rvalid), .rready(m_rready), .rdata(m_rdata), .rresp(m_rresp),
    .fifo_winc, .fifo_wdata, .fifo_wfull, .err(rd_err)
  );

  async_fifo #(.DW(DW), .AW(FIFO_AW)) u_fifo (
    .wclk(clk_rd), .wrst_n(rst_rd_n), .winc(fifo_winc), .wdata(fifo_wdata), .wfull(fifo_wfull),
    .rclk(clk_wr), .rrst_n(rst_wr_n), .rinc(fifo_rinc), .rdata(fifo_rdata), .rempty(fifo_rempty)
  );

  dma_wr_engine u_wr (
    .clk(clk_wr), .rst_n(rst_wr_n), .start(start_wr), .dst(dst_addr), .len,
    .awaddr(m_awaddr), .awlen(m_awlen), .awvalid(m_awvalid), .awready(m_awready),
    .wvalid(m_wvalid), .wready(m_wready), .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast),
    .bvalid(m_bvalid), .bready(m_bready), .bresp(m_bresp),
    .fifo_rempty, .fifo_rdata, .fifo_rinc, .done_pulse(wr_done), .err(wr_err)
  );
endmodule
