// slice_mem: slice value storage (32768x8, inferred BRAM) + importance storage (512x8).
// Both ports synchronous-read with 1-cycle latency. Array names 'mem' and 'imp_mem' are
// FROZEN for testbench hierarchical preload (see docs/interfaces.md).
module slice_mem (
  input  wire        clk,
  input  wire        a_we,   input wire [14:0] a_addr,   input wire [7:0] a_din,   // loader
  input  wire [14:0] b_addr, output reg  [7:0] b_dout,                             // engine
  input  wire        imp_we, input wire [8:0] imp_waddr, input wire [7:0] imp_din,
  input  wire [8:0]  imp_raddr, output reg [7:0] imp_dout
);

  reg [7:0] mem     [0:32767];
  reg [7:0] imp_mem [0:511];

  always @(posedge clk) begin
    if (a_we) mem[a_addr] <= a_din;
    b_dout <= mem[b_addr];
  end

  always @(posedge clk) begin
    if (imp_we) imp_mem[imp_waddr] <= imp_din;
    imp_dout <= imp_mem[imp_raddr];
  end

endmodule
