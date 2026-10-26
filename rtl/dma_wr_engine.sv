// AXI4 write master: pops the async FIFO and writes [dst, dst+len) as INCR
// bursts (4KB-safe). Pulses done_pulse after the last B response.
module dma_wr_engine import dma_pkg::*; (
  input  logic        clk, rst_n,
  input  logic        start,
  input  logic [31:0] dst, len,
  output logic [31:0] awaddr,  output logic [7:0] awlen,
  output logic        awvalid, input  logic awready,
  output logic        wvalid,  input  logic wready,
  output logic [DW-1:0] wdata, output logic [DW/8-1:0] wstrb, output logic wlast,
  input  logic        bvalid,  output logic bready, input logic [1:0] bresp,
  input  logic        fifo_rempty, input logic [DW-1:0] fifo_rdata,
  output logic        fifo_rinc,
  output logic        done_pulse,
  output logic        err
);
  typedef enum logic [2:0] {S_IDLE, S_ISSUE, S_AW, S_DATA, S_RESP, S_DONE} state_t;
  state_t      st;
  logic [31:0] cur, rem;
  logic [4:0]  cnt;
  wire  [4:0]  beats      = calc_beats(cur, rem);
  wire  [31:0] beat_bytes = 32'(beats) << 3;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; awvalid <= 1'b0; awaddr <= '0; awlen <= '0;
      cur <= '0; rem <= '0; cnt <= '0; err <= 1'b0; done_pulse <= 1'b0;
    end else begin
      done_pulse <= 1'b0;
      case (st)
        S_IDLE: if (start) begin
          cur <= dst; rem <= len; err <= 1'b0; st <= S_ISSUE;
        end
        S_ISSUE: begin
          awaddr  <= cur;
          awlen   <= 8'(beats) - 8'd1;
          awvalid <= 1'b1;
          cnt     <= beats;
          cur     <= cur + beat_bytes;
          rem     <= rem - beat_bytes;
          st      <= S_AW;
        end
        S_AW: if (awready) begin awvalid <= 1'b0; st <= S_DATA; end
        S_DATA: if (wvalid && wready) begin
          cnt <= cnt - 5'd1;
          if (cnt == 5'd1) st <= S_RESP;
        end
        S_RESP: if (bvalid) begin
          if (bresp != 2'b00) err <= 1'b1;
          st <= (rem == 32'd0) ? S_DONE : S_ISSUE;
        end
        S_DONE: begin done_pulse <= 1'b1; st <= S_IDLE; end
        default: st <= S_IDLE;
      endcase
    end
  end

  assign wvalid    = (st == S_DATA) && !fifo_rempty;
  assign wdata     = fifo_rdata;
  assign wstrb     = '1;
  assign wlast     = (cnt == 5'd1);
  assign bready    = (st == S_RESP);
  assign fifo_rinc = wvalid && wready;
endmodule
