// Behavioral AXI4 slave memory (sim only). One transaction at a time, INCR bursts.
// DDR_MODE=1 adds DDR-style timing: 4 banks x 1KB rows (bank = addr[11:10]),
// open-page policy (row hit = CL, miss = tRP+tRCD+CL, closed = tRCD+CL), and
// periodic refresh (tRFC stall every tREFI cycles). Stats are exposed for the TB.
module axi4_mem_model #(
  parameter int DW = 64, parameter int AW = 32, parameter int IDX_W = 14,
  parameter bit DDR_MODE = 0,
  parameter int SIMPLE_LAT = 1,
  parameter int CL = 4, parameter int TRCD = 4, parameter int TRP = 4,
  parameter int TREFI = 400, parameter int TRFC = 30
) (
  input  logic clk, rst_n,
  input  logic [AW-1:0] araddr, input logic [7:0] arlen, input logic arvalid, output logic arready,
  output logic rvalid, input logic rready, output logic [DW-1:0] rdata,
  output logic [1:0] rresp, output logic rlast,
  input  logic [AW-1:0] awaddr, input logic [7:0] awlen, input logic awvalid, output logic awready,
  input  logic wvalid, output logic wready, input logic [DW-1:0] wdata,
  input  logic [DW/8-1:0] wstrb, input logic wlast,
  output logic bvalid, input logic bready, output logic [1:0] bresp
);
  logic [DW-1:0] mem [0:(1<<IDX_W)-1];

  typedef enum logic [2:0] {S_IDLE, S_RWAIT, S_RDATA, S_WWAIT, S_WDATA, S_WRESP} state_t;
  state_t st;
  logic [AW-1:0] addr;
  logic [7:0]    beats_left;
  logic [15:0]   lat_cnt;

  logic          open_v   [0:3];
  logic [AW-1:0] open_row [0:3];
  logic [15:0]   ref_cnt;
  logic [15:0]   rfc_cnt;

  int unsigned row_hits, row_misses, refreshes, rd_bursts, wr_bursts;

  // Test knobs, set by the testbench through hierarchical references.
  int          stall_pct = 0;        // chance (0-100) a channel stalls on any cycle
  bit          err_en    = 0;        // return SLVERR for beats in [err_lo, err_hi]
  int unsigned err_lo    = 0;
  int unsigned err_hi    = 0;
  logic        a_stall, r_stall, w_stall, b_stall, w_err;

  function automatic bit roll();
    return int'($urandom_range(99, 0)) < stall_pct;
  endfunction
  function automatic bit in_err_range(input logic [AW-1:0] a);
    return err_en && (a >= AW'(err_lo)) && (a <= AW'(err_hi));
  endfunction

  wire ref_due    = DDR_MODE && (ref_cnt >= 16'(TREFI));
  wire can_accept = (st == S_IDLE) && (rfc_cnt == 0) && !ref_due;
  assign arready  = can_accept && !a_stall;
  assign awready  = can_accept && !a_stall && !arvalid;

  function automatic [15:0] penalty(input logic [AW-1:0] a);
    logic [1:0] b; logic [AW-1:0] r;
    b = a[11:10]; r = a >> 12;
    if (!DDR_MODE)                         return 16'(SIMPLE_LAT);
    else if (open_v[b] && open_row[b] == r) return 16'(CL);
    else if (open_v[b])                    return 16'(TRP + TRCD + CL);
    else                                   return 16'(TRCD + CL);
  endfunction

  task automatic touch_row(input logic [AW-1:0] a);
    logic [1:0] b; logic [AW-1:0] r;
    b = a[11:10]; r = a >> 12;
    if (open_v[b] && open_row[b] == r) row_hits++; else row_misses++;
    open_v[b] = 1'b1; open_row[b] = r;
  endtask

  wire [IDX_W-1:0] idx = addr[IDX_W+2:3];

  assign rvalid = (st == S_RDATA) && !r_stall;
  assign rdata  = mem[idx];
  assign rresp  = in_err_range(addr) ? 2'b10 : 2'b00;
  assign rlast  = (beats_left == 8'd0);
  assign wready = (st == S_WDATA) && !w_stall;
  assign bvalid = (st == S_WRESP) && !b_stall;
  assign bresp  = w_err ? 2'b10 : 2'b00;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; addr <= '0; beats_left <= '0; lat_cnt <= '0;
      a_stall <= 1'b0; r_stall <= 1'b0; w_stall <= 1'b0; b_stall <= 1'b0; w_err <= 1'b0;
      ref_cnt <= '0; rfc_cnt <= '0;
      for (int i = 0; i < 4; i++) begin open_v[i] <= 1'b0; open_row[i] <= '0; end
      row_hits <= 0; row_misses <= 0; refreshes <= 0; rd_bursts <= 0; wr_bursts <= 0;
    end else begin
      // A valid must stay up until its ready, so only re-roll after a handshake.
      a_stall <= roll();
      w_stall <= roll();
      if (!(rvalid && !rready)) r_stall <= roll();
      if (!(bvalid && !bready)) b_stall <= roll();

      if (rfc_cnt != 0) rfc_cnt <= rfc_cnt - 16'd1;
      if (DDR_MODE && ref_due && st == S_IDLE && rfc_cnt == 0) begin
        rfc_cnt <= 16'(TRFC); ref_cnt <= '0; refreshes <= refreshes + 1;
        for (int i = 0; i < 4; i++) open_v[i] <= 1'b0;   // refresh precharges all banks
      end else if (!ref_due) ref_cnt <= ref_cnt + 16'd1;

      case (st)
        S_IDLE: begin
          if (arvalid && arready) begin
            addr <= araddr; beats_left <= arlen; lat_cnt <= penalty(araddr);
            if (DDR_MODE) touch_row(araddr);
            rd_bursts <= rd_bursts + 1; st <= S_RWAIT;
          end else if (awvalid && awready) begin
            addr <= awaddr; beats_left <= awlen; lat_cnt <= penalty(awaddr); w_err <= 1'b0;
            if (DDR_MODE) touch_row(awaddr);
            wr_bursts <= wr_bursts + 1; st <= S_WWAIT;
          end
        end
        S_RWAIT: if (lat_cnt <= 16'd1) st <= S_RDATA; else lat_cnt <= lat_cnt - 16'd1;
        S_RDATA: if (rvalid && rready) begin
          addr <= addr + AW'(DW/8);
          if (beats_left == 0) st <= S_IDLE; else beats_left <= beats_left - 8'd1;
        end
        S_WWAIT: if (lat_cnt <= 16'd1) st <= S_WDATA; else lat_cnt <= lat_cnt - 16'd1;
        S_WDATA: if (wvalid && wready) begin
          if (in_err_range(addr)) w_err <= 1'b1;
          for (int b = 0; b < DW/8; b++)
            if (wstrb[b]) mem[idx][8*b +: 8] <= wdata[8*b +: 8];
          addr <= addr + AW'(DW/8);
          if (wlast) st <= S_WRESP; else beats_left <= beats_left - 8'd1;
        end
        S_WRESP: if (bvalid && bready) st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
