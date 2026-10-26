// AXI4 read master: splits [src, src+len) into INCR bursts that respect the
// 4KB rule and pushes returned beats into the async FIFO.
module dma_rd_engine import dma_pkg::*; (
  input  logic        clk, rst_n,
  input  logic        start,
  input  logic [31:0] src, len,
  output logic [31:0] araddr,  output logic [7:0] arlen,
  output logic        arvalid, input  logic arready,
  input  logic        rvalid,  output logic rready,
  input  logic [DW-1:0] rdata, input  logic [1:0] rresp,
  output logic        fifo_winc, output logic [DW-1:0] fifo_wdata,
  input  logic        fifo_wfull,
  output logic        err
);
  logic        ar_busy;
  logic [31:0] cur, rem;
  wire  [4:0]  beats     = calc_beats(cur, rem);
  wire  [31:0] beat_bytes = 32'(beats) << 3;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_busy <= 1'b0; arvalid <= 1'b0; araddr <= '0; arlen <= '0;
      cur <= '0; rem <= '0; err <= 1'b0;
    end else begin
      if (arvalid && arready) arvalid <= 1'b0;

      if (start) begin
        cur <= src; rem <= len; ar_busy <= 1'b1; err <= 1'b0;
      end else if (ar_busy && !arvalid) begin
        araddr  <= cur;
        arlen   <= 8'(beats) - 8'd1;
        arvalid <= 1'b1;
        cur     <= cur + beat_bytes;
        rem     <= rem - beat_bytes;
        if (rem == beat_bytes) ar_busy <= 1'b0;
      end

      if (rvalid && rready && rresp != 2'b00) err <= 1'b1;
    end
  end

  assign rready     = !fifo_wfull;
  assign fifo_winc  = rvalid && rready;
  assign fifo_wdata = rdata;
endmodule
