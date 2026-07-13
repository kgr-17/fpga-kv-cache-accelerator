// ratio_calc: serial restoring divider computing (num*100)/den into ratio_x100,
// saturated at 9999; result 0 if den == 0. Runs once per RUN (display-only).
// num*100 needs 39 bits -> 40-bit dividend/quotient. A start while busy restarts.
module ratio_calc (
  input  wire        clk, rst,
  input  wire        start,          // strobe at run_done
  input  wire [31:0] num,            // orig_bytes
  input  wire [31:0] den,            // comp_bytes
  output reg  [15:0] ratio_x100,     // (num*100)/den, saturated at 9999; 0 if den==0
  output reg         done            // 1-cycle strobe when finished
);

  localparam ST_IDLE = 2'd0;
  localparam ST_DIV  = 2'd1;
  localparam ST_FIN  = 2'd2;

  reg [1:0]  state;
  reg [39:0] dividend;   // shifts left; MSB feeds the remainder each iteration
  reg [39:0] quotient;
  reg [32:0] rem;        // one bit wider than den for the trial subtract
  reg [31:0] den_r;
  reg [5:0]  cnt;

  // Restoring-division step: shift in next dividend bit, trial-subtract divisor.
  // Invariant rem < den ensures rem[32] == 0, so borrow shows up in rem_sub[32].
  wire [32:0] rem_next = {rem[31:0], dividend[39]};
  wire [32:0] rem_sub  = rem_next - {1'b0, den_r};

  always @(posedge clk) begin
    if (rst) begin
      state      <= ST_IDLE;
      ratio_x100 <= 16'd0;
      done       <= 1'b0;
      dividend   <= 40'd0;
      quotient   <= 40'd0;
      rem        <= 33'd0;
      den_r      <= 32'd0;
      cnt        <= 6'd0;
    end else begin
      done <= 1'b0;
      if (start) begin           // start takes priority: restarts even if busy
        if (den == 32'd0) begin
          ratio_x100 <= 16'd0;
          done       <= 1'b1;
          state      <= ST_IDLE;
        end else begin
          // num*100 = num*64 + num*32 + num*4 (shift-add, no multiplier)
          dividend <= ({8'd0, num} << 6) + ({8'd0, num} << 5) + ({8'd0, num} << 2);
          quotient <= 40'd0;
          rem      <= 33'd0;
          den_r    <= den;
          cnt      <= 6'd39;
          state    <= ST_DIV;
        end
      end else begin
        case (state)
          ST_DIV: begin
            dividend <= {dividend[38:0], 1'b0};
            if (!rem_sub[32]) begin   // rem_next >= den: keep subtraction
              rem      <= rem_sub;
              quotient <= {quotient[38:0], 1'b1};
            end else begin            // restore
              rem      <= rem_next;
              quotient <= {quotient[38:0], 1'b0};
            end
            if (cnt == 6'd0) state <= ST_FIN;
            else             cnt   <= cnt - 6'd1;
          end
          ST_FIN: begin
            ratio_x100 <= (quotient > 40'd9999) ? 16'd9999 : quotient[15:0];
            done       <= 1'b1;
            state      <= ST_IDLE;
          end
          default: state <= ST_IDLE;
        endcase
      end
    end
  end

endmodule
