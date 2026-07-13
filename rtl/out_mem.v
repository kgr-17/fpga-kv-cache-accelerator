// out_mem: compressed output stream storage, 36864x8, inferred BRAM.
// Synchronous read, 1-cycle latency. Array name 'mem' is FROZEN for testbench access.
// Out-of-range addresses (>= 36864) never occur by construction (docs/interfaces.md).
module out_mem (
  input  wire        clk,
  input  wire        a_we,   input wire [15:0] a_addr, input wire [7:0] a_din,  // engine
  input  wire [15:0] b_addr, output reg  [7:0] b_dout                           // proto DRAIN
);

  reg [7:0] mem [0:36863];

  always @(posedge clk) begin
    if (a_we) mem[a_addr] <= a_din;
    b_dout <= mem[b_addr];
  end

endmodule
