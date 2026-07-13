`timescale 1ns/1ps
// rle_enc.v - zero-run RLE encoder (docs/interfaces.md, docs/encoding.md)
// Nonzero byte b        -> emit b
// Run of n zeros (n<=64)-> emit 0x00, n  (run flushed at i_eov)
// Consuming one input byte may require up to 3 output bytes (marker, count,
// then a saved nonzero byte) over successive cycles; i_ready deasserts while
// draining. At most one output byte per cycle; o_last marks the vector's final
// output byte. Run length never exceeds 64 by construction (<= vec_len).
module rle_enc (
  input  wire       clk,
  input  wire       rst,
  input  wire [7:0] i_data,
  input  wire       i_valid,
  input  wire       i_eov,
  output wire       i_ready,
  output reg  [7:0] o_data,
  output reg        o_valid,
  output reg        o_last,
  input  wire       o_ready
);

  localparam S_IDLE = 2'd0;  // accepting input
  localparam S_CNT  = 2'd1;  // run-count byte pending (marker already in o_data)
  localparam S_BYTE = 2'd2;  // saved nonzero byte pending (after run pair)

  reg [1:0] state;
  reg [6:0] run;       // pending zero-run length, 0..64
  reg [7:0] cnt_byte;  // run count to emit in S_CNT
  reg       cnt_last;  // count byte ends the vector (eov flush on a zero)
  reg [7:0] sav_byte;  // nonzero byte that terminated a run
  reg       sav_last;  // saved byte ends the vector

  // Accept input only when idle and the output register is free (or being
  // drained this cycle), so every accepted byte has room for its first output.
  assign i_ready = (state == S_IDLE) && (!o_valid || o_ready);

  always @(posedge clk) begin
    if (rst) begin
      state    <= S_IDLE;
      run      <= 7'd0;
      cnt_byte <= 8'd0;
      cnt_last <= 1'b0;
      sav_byte <= 8'd0;
      sav_last <= 1'b0;
      o_data   <= 8'd0;
      o_valid  <= 1'b0;
      o_last   <= 1'b0;
    end else begin
      if (o_valid && o_ready) begin  // output consumed (loads below override)
        o_valid <= 1'b0;
        o_last  <= 1'b0;
      end

      case (state)
        S_IDLE: begin
          if (i_valid && i_ready) begin
            if (i_data == 8'h00) begin
              if (i_eov) begin
                // flush run (including this zero): emit marker now, count next
                o_data   <= 8'h00;
                o_valid  <= 1'b1;
                o_last   <= 1'b0;
                cnt_byte <= {1'b0, run} + 8'd1;
                cnt_last <= 1'b1;
                run      <= 7'd0;
                state    <= S_CNT;
              end else begin
                run <= run + 7'd1;  // absorb zero, no output this byte
              end
            end else begin
              if (run != 7'd0) begin
                // close the run, then the nonzero byte: marker, count, byte
                o_data   <= 8'h00;
                o_valid  <= 1'b1;
                o_last   <= 1'b0;
                cnt_byte <= {1'b0, run};
                cnt_last <= 1'b0;
                sav_byte <= i_data;
                sav_last <= i_eov;
                run      <= 7'd0;
                state    <= S_CNT;
              end else begin
                o_data  <= i_data;
                o_valid <= 1'b1;
                o_last  <= i_eov;
              end
            end
          end
        end

        S_CNT: begin
          if (o_valid && o_ready) begin
            o_data  <= cnt_byte;
            o_valid <= 1'b1;
            o_last  <= cnt_last;
            state   <= cnt_last ? S_IDLE : S_BYTE;
          end
        end

        S_BYTE: begin
          if (o_valid && o_ready) begin
            o_data  <= sav_byte;
            o_valid <= 1'b1;
            o_last  <= sav_last;
            state   <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
