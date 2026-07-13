// delta_dec: inverse of delta_enc (docs/encoding.md). Combinational
// valid/ready pass-through; v[0] = d[0] (i_sov), v[i] = (v[i-1] + d[i]) mod 256.
// prev updates to the RESTORED value on each accepted transfer.
module delta_dec (
  input  wire       clk,
  input  wire       rst,
  input  wire [7:0] i_data,
  input  wire       i_valid,
  input  wire       i_sov,
  output wire       i_ready,
  output wire [7:0] o_data,
  output wire       o_valid,
  input  wire       o_ready
);

  reg [7:0] prev;

  assign i_ready = o_ready;
  assign o_valid = i_valid;
  assign o_data  = i_sov ? i_data : (i_data + prev);  // mod-256 wrap is free

  always @(posedge clk) begin
    if (rst)
      prev <= 8'd0;
    else if (i_valid && i_ready)
      prev <= o_data;
  end

endmodule
