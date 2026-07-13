`timescale 1ns/1ps
// uart_tx.v — 8N1 UART transmitter (see docs/interfaces.md, FROZEN contract)
// o_tx idles high. o_ready is high when idle; a byte is accepted on
// i_valid && o_ready and serialized LSB first.
module uart_tx #(parameter CLKS_PER_BIT = 109) (
  input  wire       clk, rst,
  input  wire [7:0] i_data,
  input  wire       i_valid,
  output wire       o_ready,       // high when idle (can accept); transfer on valid&&ready
  output reg        o_tx           // idles high
);

  localparam [1:0] S_IDLE  = 2'd0,
                   S_START = 2'd1,
                   S_DATA  = 2'd2,
                   S_STOP  = 2'd3;

  reg [1:0]  state;
  reg [15:0] cnt;                  // clock count within the current bit
  reg [2:0]  bit_idx;
  reg [7:0]  data;

  assign o_ready = (state == S_IDLE);

  always @(posedge clk) begin
    if (rst) begin
      state   <= S_IDLE;
      cnt     <= 16'd0;
      bit_idx <= 3'd0;
      data    <= 8'd0;
      o_tx    <= 1'b1;
    end else begin
      case (state)
        S_IDLE: begin
          cnt     <= 16'd0;
          bit_idx <= 3'd0;
          o_tx    <= 1'b1;
          if (i_valid) begin       // o_ready is high in this state
            data  <= i_data;
            o_tx  <= 1'b0;         // start bit
            state <= S_START;
          end
        end

        S_START: begin
          if (cnt == CLKS_PER_BIT-1) begin
            cnt   <= 16'd0;
            o_tx  <= data[0];      // LSB first
            state <= S_DATA;
          end else begin
            cnt <= cnt + 16'd1;
          end
        end

        S_DATA: begin
          if (cnt == CLKS_PER_BIT-1) begin
            cnt <= 16'd0;
            if (bit_idx == 3'd7) begin
              bit_idx <= 3'd0;
              o_tx    <= 1'b1;     // stop bit
              state   <= S_STOP;
            end else begin
              bit_idx <= bit_idx + 3'd1;
              o_tx    <= data[bit_idx + 3'd1];
            end
          end else begin
            cnt <= cnt + 16'd1;
          end
        end

        S_STOP: begin
          if (cnt == CLKS_PER_BIT-1) begin
            cnt   <= 16'd0;
            state <= S_IDLE;
          end else begin
            cnt <= cnt + 16'd1;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
