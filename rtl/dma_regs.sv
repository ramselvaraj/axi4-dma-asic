// AXI4-Lite register block + interrupt logic.
//
//  0x00 CTRL        [0] START (self-clearing, ignored while busy)
//  0x04 STATUS      [0] busy [1] done [2] rd_err [3] wr_err [4] cfg_err
//  0x08 SRC_ADDR    byte address, 8-byte aligned
//  0x0C DST_ADDR    byte address, 8-byte aligned
//  0x10 LEN         bytes, non-zero multiple of 8
//  0x14 IRQ_EN      [0] done [1] error
//  0x18 IRQ_STATUS  [0] done [1] error   (write-1-to-clear)
//
// irq (level) = |(IRQ_STATUS & IRQ_EN). SRC/DST/LEN are locked while busy.
module dma_regs (
  input  logic        clk, rst_n,
  input  logic [7:0]  s_awaddr,  input  logic s_awvalid, output logic s_awready,
  input  logic [31:0] s_wdata,   input  logic [3:0] s_wstrb,
  input  logic        s_wvalid,  output logic s_wready,
  output logic [1:0]  s_bresp,   output logic s_bvalid,  input  logic s_bready,
  input  logic [7:0]  s_araddr,  input  logic s_arvalid, output logic s_arready,
  output logic [31:0] s_rdata,   output logic [1:0] s_rresp,
  output logic        s_rvalid,  input  logic s_rready,

  output logic [31:0] src_addr, dst_addr, len,
  output logic        start,
  input  logic        done_pulse, rd_err, wr_err,
  output logic        irq
);
  logic        busy, done, rd_err_q, wr_err_q, cfg_err;
  logic [1:0]  irq_en, irq_status;

  wire wr_fire = s_awvalid && s_wvalid && !s_bvalid;
  assign s_awready = wr_fire;
  assign s_wready  = wr_fire;
  assign s_bresp   = 2'b00;
  assign s_rresp   = 2'b00;
  assign s_arready = s_arvalid && !s_rvalid;
  assign irq       = |(irq_status & irq_en);

  wire cfg_bad = (len == 32'd0) || (len[2:0] != 3'd0) ||
                 (src_addr[2:0] != 3'd0) || (dst_addr[2:0] != 3'd0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_bvalid <= 1'b0; busy <= 1'b0; done <= 1'b0; start <= 1'b0;
      rd_err_q <= 1'b0; wr_err_q <= 1'b0; cfg_err <= 1'b0;
      src_addr <= '0; dst_addr <= '0; len <= '0;
      irq_en <= '0; irq_status <= '0;
    end else begin
      start <= 1'b0;
      if (wr_fire)        s_bvalid <= 1'b1;
      else if (s_bready)  s_bvalid <= 1'b0;

      if (wr_fire) begin
        case (s_awaddr[4:2])
          3'd0: if (s_wdata[0] && !busy) begin
                  if (cfg_bad) begin
                    cfg_err <= 1'b1; irq_status[1] <= 1'b1;
                  end else begin
                    start <= 1'b1; busy <= 1'b1; done <= 1'b0;
                    rd_err_q <= 1'b0; wr_err_q <= 1'b0; cfg_err <= 1'b0;
                  end
                end
          3'd2: if (!busy) src_addr <= s_wdata;
          3'd3: if (!busy) dst_addr <= s_wdata;
          3'd4: if (!busy) len      <= s_wdata;
          3'd5: irq_en     <= s_wdata[1:0];
          3'd6: irq_status <= irq_status & ~s_wdata[1:0];
          default: ;
        endcase
      end

      // hardware events win over a same-cycle W1C clear
      if (done_pulse) begin
        busy <= 1'b0; done <= 1'b1;
        rd_err_q <= rd_err; wr_err_q <= wr_err;
        irq_status[0] <= 1'b1;
        if (rd_err || wr_err) irq_status[1] <= 1'b1;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin s_rvalid <= 1'b0; s_rdata <= '0; end
    else begin
      if (s_arready) begin
        s_rvalid <= 1'b1;
        case (s_araddr[4:2])
          3'd0: s_rdata <= 32'd0;
          3'd1: s_rdata <= {27'd0, cfg_err, wr_err_q, rd_err_q, done, busy};
          3'd2: s_rdata <= src_addr;
          3'd3: s_rdata <= dst_addr;
          3'd4: s_rdata <= len;
          3'd5: s_rdata <= {30'd0, irq_en};
          3'd6: s_rdata <= {30'd0, irq_status};
          default: s_rdata <= 32'd0;
        endcase
      end else if (s_rready) s_rvalid <= 1'b0;
    end
  end
endmodule
