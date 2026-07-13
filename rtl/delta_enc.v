`timescale 1ns/1ps
// delta_enc.v - per-vector delta encoder (docs/interfaces.md, docs/encoding.md)
// Combinational pass-through of valid/ready/eov; only the prev byte is registered.
// d[0] = v[0] (i_sov), d[i] = (v[i] - v[i-1]) mod 256.
module delta_enc (
  input  wire       clk,
  input  wire       rst,
  input  wire [7:0] i_data,
  input  wire       i_valid,
  input  wire       i_sov,
  input  wire       i_eov,
  output wire       i_ready,
  output wire [7:0] o_data,
  output wire       o_valid,
  output wire       o_eov,
  input  wire       o_ready
);

  reg [7:0] prev;

  assign i_ready = o_ready;
  assign o_valid = i_valid;
  assign o_eov   = i_eov;
  // 8-bit subtraction is naturally mod 256
  assign o_data  = i_sov ? i_data : (i_data - prev);

  always @(posedge clk) begin
    if (rst)
      prev <= 8'h00;
    else if (i_valid && i_ready)
      prev <= i_data;
  end

endmodule
