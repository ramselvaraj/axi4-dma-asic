// Gray-code asynchronous FIFO (Cummings style), first-word-fall-through read.
module async_fifo #(
  parameter int DW = 64,
  parameter int AW = 5            // depth = 2**AW
) (
  input  logic          wclk, wrst_n, winc,
  input  logic [DW-1:0] wdata,
  output logic          wfull,
  input  logic          rclk, rrst_n, rinc,
  output logic [DW-1:0] rdata,
  output logic          rempty
);
  logic [DW-1:0] mem [0:(1<<AW)-1];
  logic [AW:0] wbin, wgray, rbin, rgray;
  logic [AW:0] wq1_rgray, wq2_rgray, rq1_wgray, rq2_wgray;

  wire [AW:0] wbin_n  = wbin + {{AW{1'b0}}, (winc & ~wfull)};
  wire [AW:0] wgray_n = (wbin_n >> 1) ^ wbin_n;
  wire [AW:0] rbin_n  = rbin + {{AW{1'b0}}, (rinc & ~rempty)};
  wire [AW:0] rgray_n = (rbin_n >> 1) ^ rbin_n;

  // write domain
  always_ff @(posedge wclk or negedge wrst_n)
    if (!wrst_n) begin wbin <= '0; wgray <= '0; end
    else         begin wbin <= wbin_n; wgray <= wgray_n; end

  always_ff @(posedge wclk)
    if (winc && !wfull) mem[wbin[AW-1:0]] <= wdata;

  always_ff @(posedge wclk or negedge wrst_n)
    if (!wrst_n) {wq2_rgray, wq1_rgray} <= '0;
    else         {wq2_rgray, wq1_rgray} <= {wq1_rgray, rgray};

  always_ff @(posedge wclk or negedge wrst_n)
    if (!wrst_n) wfull <= 1'b0;
    else         wfull <= (wgray_n == {~wq2_rgray[AW:AW-1], wq2_rgray[AW-2:0]});

  // read domain
  always_ff @(posedge rclk or negedge rrst_n)
    if (!rrst_n) begin rbin <= '0; rgray <= '0; end
    else         begin rbin <= rbin_n; rgray <= rgray_n; end

  always_ff @(posedge rclk or negedge rrst_n)
    if (!rrst_n) {rq2_wgray, rq1_wgray} <= '0;
    else         {rq2_wgray, rq1_wgray} <= {rq1_wgray, wgray};

  always_ff @(posedge rclk or negedge rrst_n)
    if (!rrst_n) rempty <= 1'b1;
    else         rempty <= (rgray_n == rq2_wgray);

  assign rdata = mem[rbin[AW-1:0]];
endmodule
