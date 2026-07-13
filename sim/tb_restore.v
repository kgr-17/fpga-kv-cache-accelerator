`timescale 1ns/1ps
// tb_restore: hardware decompressor unit test. Preloads out_mem with the
// engine case's compressed stream (eng_expected.hex), runs restore_ctrl, and
// compares the produced stream byte-for-byte against eng_restored.hex
// (bitmap + kept original vectors) under randomized o_ready backpressure.
// Runs TWICE to prove the sequencer and decoders fully reset between runs.
module tb_restore;

  parameter VEC_DIR = "../../../../sim/vectors";

  reg clk = 1'b0;
  reg rst = 1'b1;
  always #5 clk = ~clk;

  // DUTs
  reg         start;
  reg  [9:0]  entry_count;
  reg  [6:0]  vec_len;
  wire        active, done, o_valid;
  wire [7:0]  o_data;
  reg         o_ready_r;
  wire [15:0] om_addr;
  wire [7:0]  om_data;

  out_mem u_out (
    .clk(clk),
    .a_we(1'b0), .a_addr(16'd0), .a_din(8'd0),
    .b_addr(om_addr), .b_dout(om_data)
  );

  restore_ctrl u_dut (
    .clk(clk), .rst(rst),
    .i_start(start),
    .i_entry_count(entry_count), .i_vec_len(vec_len),
    .o_active(active),
    .om_addr(om_addr), .om_data(om_data),
    .o_data(o_data), .o_valid(o_valid), .o_ready(o_ready_r),
    .o_done(done)
  );

  // vectors
  reg [7:0] params   [0:3];
  reg [7:0] expected [0:1023];
  integer   n_exp;

  // received
  reg [7:0] got [0:1023];
  integer   n_got;

  integer seed = 32'h5EED;
  integer i, run_i;
  reg done_seen;

  // collect accepted output bytes; randomize backpressure
  always @(posedge clk) begin
    if (o_valid && o_ready_r) begin
      got[n_got] <= o_data;
      n_got      <= n_got + 1;
    end
    o_ready_r <= ($random(seed) & 3) != 0;   // ready ~75% of cycles
    if (done)
      done_seen <= 1'b1;
  end

  // global timeout
  initial begin
    #2_000_000;
    $display("FAIL: tb_restore global timeout");
    $finish;
  end

  task run_once;
    begin
      n_got     = 0;
      done_seen = 1'b0;
      @(negedge clk);
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      while (!done_seen)
        @(negedge clk);
      repeat (4) @(negedge clk);
      if (n_got !== n_exp) begin
        $display("FAIL: tb_restore byte count got %0d expected %0d", n_got, n_exp);
        $finish;
      end
      for (i = 0; i < n_exp; i = i + 1)
        if (got[i] !== expected[i]) begin
          $display("FAIL: tb_restore byte %0d got %02x expected %02x",
                   i, got[i], expected[i]);
          $finish;
        end
      if (active !== 1'b0) begin
        $display("FAIL: tb_restore o_active stuck after done");
        $finish;
      end
    end
  endtask

  initial begin
    o_ready_r = 1'b0;
    start     = 1'b0;
    n_got     = 0;
    done_seen = 1'b0;

    for (i = 0; i < 1024; i = i + 1)
      expected[i] = 8'hxx;
    $readmemh({VEC_DIR, "/eng_expected.hex"}, u_out.mem);
    $readmemh({VEC_DIR, "/eng_params.hex"},   params);
    $readmemh({VEC_DIR, "/eng_restored.hex"}, expected);

    entry_count = {params[1][1:0], params[0]};
    vec_len     = params[2][6:0];

    n_exp = 0;
    while (n_exp < 1024 && expected[n_exp] !== 8'hxx)
      n_exp = n_exp + 1;
    if (n_exp == 0) begin
      $display("FAIL: tb_restore empty expected vector file");
      $finish;
    end

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (3) @(negedge clk);

    for (run_i = 0; run_i < 2; run_i = run_i + 1)
      run_once;

    $display("PASS: tb_restore");
    $finish;
  end

endmodule
