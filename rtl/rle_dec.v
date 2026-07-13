// rle_dec: inverse of rle_enc (docs/encoding.md). Literal byte -> itself;
// marker pair (0x00, n) -> n zero bytes emitted over n cycles. i_ready is low
// while a zero run drains. At most 1 output byte per cycle. i_clr resets state
// at each vector boundary (defensive: a well-formed stream ends runs exactly
// at the boundary anyway).
module rle_dec (
  input  wire       clk,
  input  wire       rst,
  input  wire       i_clr,
  input  wire [7:0] i_data,
  input  wire       i_valid,
  output wire       i_ready,
  output reg  [7:0] o_data,
  output reg        o_valid,
  input  wire       o_ready
);

  localparam [1:0] R_IDLE = 2'd0,   // expect literal or 0x00 marker
                   R_CNT  = 2'd1,   // expect run-length byte
                   R_LIT  = 2'd2,   // presenting a literal byte
                   R_ZERO = 2'd3;   // draining a zero run

  reg [1:0] state;
  reg [6:0] zeros_left;             // run length <= 64

  assign i_ready = (state == R_IDLE) || (state == R_CNT);

  always @(posedge clk) begin
    if (rst) begin
      state      <= R_IDLE;
      zeros_left <= 7'd0;
      o_data     <= 8'd0;
      o_valid    <= 1'b0;
    end else if (i_clr) begin
      state      <= R_IDLE;
      zeros_left <= 7'd0;
      o_valid    <= 1'b0;
    end else begin
      case (state)
        R_IDLE: if (i_valid) begin
          if (i_data == 8'h00)
            state <= R_CNT;
          else begin
            o_data  <= i_data;
            o_valid <= 1'b1;
            state   <= R_LIT;
          end
        end

        R_CNT: if (i_valid) begin
          zeros_left <= i_data[6:0];
          o_data     <= 8'h00;
          o_valid    <= 1'b1;
          state      <= R_ZERO;
        end

        R_LIT: if (o_ready) begin
          o_valid <= 1'b0;
          state   <= R_IDLE;
        end

        R_ZERO: if (o_ready) begin
          if (zeros_left <= 7'd1) begin
            o_valid <= 1'b0;
            state   <= R_IDLE;
          end else
            zeros_left <= zeros_left - 7'd1;   // o_valid stays high, next zero
        end
      endcase
    end
  end

endmodule
