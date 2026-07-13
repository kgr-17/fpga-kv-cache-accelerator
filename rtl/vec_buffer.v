// vec_buffer: 128-byte distributed-LUTRAM scratch for one RLE-encoded vector.
// Always ready. clr resets the write pointer for a new vector. done is a
// 1-cycle strobe the cycle after the i_last byte is written; o_clen is the
// byte count of the vector, valid when done pulses. Max legal clen = 96.
module vec_buffer (
  input  wire       clk,
  input  wire       rst,
  input  wire       clr,
  input  wire [7:0] i_data,
  input  wire       i_valid,
  input  wire       i_last,
  output reg  [7:0] o_clen,
  output reg        done,
  input  wire [6:0] rd_addr,
  output wire [7:0] rd_data
);

  (* ram_style = "distributed" *) reg [7:0] mem [0:127];  // no reset (LUTRAM contents)

  reg [6:0] wptr;

  // Asynchronous read (distributed RAM).
  assign rd_data = mem[rd_addr];

  // Synchronous write at the current write pointer.
  always @(posedge clk) begin
    if (i_valid)
      mem[wptr] <= i_data;
  end

  always @(posedge clk) begin
    if (rst) begin
      wptr   <= 7'd0;
      o_clen <= 8'd0;
      done   <= 1'b0;
    end else begin
      done <= 1'b0;
      if (clr) begin
        wptr <= 7'd0;
      end else if (i_valid) begin
        wptr <= wptr + 7'd1;
        if (i_last) begin
          // Byte count includes the byte being written this cycle.
          o_clen <= {1'b0, wptr} + 8'd1;
          done   <= 1'b1;
        end
      end
    end
  end

endmodule
