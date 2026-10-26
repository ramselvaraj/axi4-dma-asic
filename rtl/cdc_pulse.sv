// Single-cycle pulse crossing via toggle + 2FF synchronizer.
// Source pulses must be spaced by more than ~3 destination cycles.
module cdc_pulse (
  input  logic src_clk, src_rst_n, src_pulse,
  input  logic dst_clk, dst_rst_n,
  output logic dst_pulse
);
  logic tgl;
  logic [2:0] sync;

  always_ff @(posedge src_clk or negedge src_rst_n)
    if (!src_rst_n)     tgl <= 1'b0;
    else if (src_pulse) tgl <= ~tgl;

  always_ff @(posedge dst_clk or negedge dst_rst_n)
    if (!dst_rst_n) sync <= '0;
    else            sync <= {sync[1:0], tgl};

  assign dst_pulse = sync[2] ^ sync[1];
endmodule
