`timescale 1ns/1ps
// uart_rx.v — 8N1 UART receiver (see docs/interfaces.md, FROZEN contract)
// 2-FF input synchronizer inside. Majority-of-3 vote sampled at counts
// MID-1, MID, MID+1 (MID = CLKS_PER_BIT/2). Resyncs bit timing on every
// start-bit falling edge; aborts if the start bit is no longer low at
// mid-start. Frame error (stop bit voted low): byte discarded silently.
module uart_rx #(parameter CLKS_PER_BIT = 109) (
  input  wire       clk, rst,
  input  wire       i_rx,          // raw pin; 2-FF synchronizer INSIDE this module
  output reg  [7:0] o_data,
  output reg        o_valid        // 1-cycle strobe when a byte is received
);

  localparam integer MID = CLKS_PER_BIT / 2;

  localparam [1:0] S_IDLE  = 2'd0,
                   S_START = 2'd1,
                   S_DATA  = 2'd2,
                   S_STOP  = 2'd3;

  reg [1:0]  state;
  reg [15:0] cnt;                  // clock count within the current bit
  reg [2:0]  bit_idx;
  reg [7:0]  shift;
  reg        rx_ff1, rx_ff2;       // 2-FF synchronizer
  reg        rx_prev;              // for falling-edge detect
  reg        s0, s1;               // samples taken at MID-1 and MID

  // third sample is rx_ff2 itself at the cycle where cnt == MID+1
  wire vote = (s0 & s1) | (s0 & rx_ff2) | (s1 & rx_ff2);

  always @(posedge clk) begin
    if (rst) begin
      rx_ff1  <= 1'b1;
      rx_ff2  <= 1'b1;
      rx_prev <= 1'b1;
      state   <= S_IDLE;
      cnt     <= 16'd0;
      bit_idx <= 3'd0;
      shift   <= 8'd0;
      s0      <= 1'b0;
      s1      <= 1'b0;
      o_data  <= 8'd0;
      o_valid <= 1'b0;
    end else begin
      rx_ff1  <= i_rx;
      rx_ff2  <= rx_ff1;
      rx_prev <= rx_ff2;
      o_valid <= 1'b0;

      // mid-bit sample capture, shared by all receiving states
      if (state != S_IDLE) begin
        if (cnt == MID-1) s0 <= rx_ff2;
        if (cnt == MID)   s1 <= rx_ff2;
      end

      case (state)
        S_IDLE: begin
          cnt     <= 16'd0;
          bit_idx <= 3'd0;
          if (rx_prev && !rx_ff2)      // start-bit falling edge: resync here
            state <= S_START;
        end

        S_START: begin
          if ((cnt == MID+1) && vote) begin
            state <= S_IDLE;           // start bit not low at mid-start: abort
            cnt   <= 16'd0;
          end else if (cnt == CLKS_PER_BIT-1) begin
            cnt   <= 16'd0;
            state <= S_DATA;
          end else begin
            cnt <= cnt + 16'd1;
          end
        end

        S_DATA: begin
          if (cnt == MID+1)
            shift <= {vote, shift[7:1]};   // LSB first
          if (cnt == CLKS_PER_BIT-1) begin
            cnt <= 16'd0;
            if (bit_idx == 3'd7) begin
              bit_idx <= 3'd0;
              state   <= S_STOP;
            end else begin
              bit_idx <= bit_idx + 3'd1;
            end
          end else begin
            cnt <= cnt + 16'd1;
          end
        end

        S_STOP: begin
          // decide at mid-stop and return to idle immediately: gives slack for
          // baud-rate error and allows resync on the next start edge
          if (cnt == MID+1) begin
            if (vote) begin
              o_data  <= shift;
              o_valid <= 1'b1;
            end
            // vote low = frame error: discard silently
            state <= S_IDLE;
            cnt   <= 16'd0;
          end else begin
            cnt <= cnt + 16'd1;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
