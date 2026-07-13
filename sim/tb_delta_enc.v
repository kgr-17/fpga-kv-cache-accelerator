`timescale 1ns/1ps
// tb_delta_enc.v - self-checking TB for delta_enc (pure Verilog-2001).
// For each family {constant, ramp, wrap, random, len1}: streams <fam>_in.hex
// through the DUT vector by vector (i_sov on byte 0, i_eov on last byte) with
// randomized i_valid gaps and randomized o_ready backpressure, and compares
// the accepted output stream byte-for-byte against <fam>_delta.hex.
module tb_delta_enc;

  parameter VEC_DIR = "../../../../sim/vectors";

  reg        clk, rst;
  reg  [7:0] i_data;
  reg        i_valid, i_sov, i_eov;
  wire       i_ready;
  wire [7:0] o_data;
  wire       o_valid, o_eov;
  reg        o_ready;

  delta_enc dut (
    .clk(clk), .rst(rst),
    .i_data(i_data), .i_valid(i_valid), .i_sov(i_sov), .i_eov(i_eov),
    .i_ready(i_ready),
    .o_data(o_data), .o_valid(o_valid), .o_eov(o_eov),
    .o_ready(o_ready)
  );

  // 100 MHz clock
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // global timeout watchdog
  initial begin
    #200_000_000;
    $display("FAIL: tb_delta_enc global timeout");
    $finish;
  end

  // vector storage (sized generously)
  reg [7:0] in_arr  [0:2047];
  reg [7:0] exp_arr [0:2047];
  reg [7:0] meta_arr[0:63];

  // captured output for the vector in flight
  reg [7:0] cap_data [0:127];
  reg       cap_eov  [0:127];
  integer   cap_cnt;

  // input transfer that occurred at the most recent posedge
  // (TB drives at negedge, so this is race-free)
  reg xfer_in;
  always @(posedge clk) xfer_in <= i_valid & i_ready;

  // randomized downstream backpressure, ~75% ready
  always @(negedge clk) begin
    if (rst) o_ready = 1'b1;
    else     o_ready = ({$random} % 4 != 0);
  end

  // output monitor: capture accepted output bytes
  always @(posedge clk) begin
    if (!rst && o_valid && o_ready) begin
      if (cap_cnt < 128) begin
        cap_data[cap_cnt] = o_data;
        cap_eov [cap_cnt] = o_eov;
      end
      cap_cnt = cap_cnt + 1;
    end
  end

  // drive one input byte with a random leading gap; return once accepted
  task send_byte;
    input [7:0] b;
    input       sov;
    input       eov;
    integer gap;
    begin
      gap = {$random} % 3;
      while (gap > 0) begin
        i_valid = 1'b0; i_sov = 1'b0; i_eov = 1'b0;
        @(negedge clk);
        gap = gap - 1;
      end
      i_valid = 1'b1; i_data = b; i_sov = sov; i_eov = eov;
      @(negedge clk);
      while (!xfer_in) @(negedge clk);
      i_valid = 1'b0; i_sov = 1'b0; i_eov = 1'b0;
    end
  endtask

  // run every vector of the currently loaded family
  task run_family;
    input [8*8-1:0] fam;
    integer v, j, vlen, nvec, base, guard;
    begin
      // guard against silently passing when $readmemh could not open the files
      if ((^meta_arr[0] === 1'bx) || (^meta_arr[1] === 1'bx)) begin
        $display("FAIL: tb_delta_enc %0s meta not loaded (check VEC_DIR)", fam);
        $finish;
      end
      vlen = meta_arr[0];
      nvec = meta_arr[1];
      base = 0;
      for (v = 0; v < nvec; v = v + 1) begin
        cap_cnt = 0;
        for (j = 0; j < vlen; j = j + 1)
          send_byte(in_arr[base + j], (j == 0), (j == vlen - 1));
        guard = 0;
        while (cap_cnt < vlen) begin
          @(negedge clk);
          guard = guard + 1;
          if (guard > 100000) begin
            $display("FAIL: tb_delta_enc %0s vec %0d output stalled", fam, v);
            $finish;
          end
        end
        repeat (4) @(negedge clk);  // settle: catch spurious extra bytes
        if (cap_cnt != vlen) begin
          $display("FAIL: tb_delta_enc %0s vec %0d got %0d bytes exp %0d",
                   fam, v, cap_cnt, vlen);
          $finish;
        end
        for (j = 0; j < vlen; j = j + 1) begin
          if (cap_data[j] !== exp_arr[base + j]) begin
            $display("FAIL: tb_delta_enc %0s vec %0d byte %0d got %02h exp %02h",
                     fam, v, j, cap_data[j], exp_arr[base + j]);
            $finish;
          end
          if (cap_eov[j] !== (j == vlen - 1)) begin
            $display("FAIL: tb_delta_enc %0s vec %0d byte %0d bad o_eov", fam, v, j);
            $finish;
          end
        end
        base = base + vlen;
      end
    end
  endtask

  initial begin
    rst = 1'b1;
    i_valid = 1'b0; i_data = 8'd0; i_sov = 1'b0; i_eov = 1'b0;
    o_ready = 1'b1;
    cap_cnt = 0;
    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);

    $readmemh({VEC_DIR, "/constant_in.hex"},    in_arr);
    $readmemh({VEC_DIR, "/constant_delta.hex"}, exp_arr);
    $readmemh({VEC_DIR, "/constant_meta.hex"},  meta_arr);
    run_family("constant");

    $readmemh({VEC_DIR, "/ramp_in.hex"},    in_arr);
    $readmemh({VEC_DIR, "/ramp_delta.hex"}, exp_arr);
    $readmemh({VEC_DIR, "/ramp_meta.hex"},  meta_arr);
    run_family("ramp");

    $readmemh({VEC_DIR, "/wrap_in.hex"},    in_arr);
    $readmemh({VEC_DIR, "/wrap_delta.hex"}, exp_arr);
    $readmemh({VEC_DIR, "/wrap_meta.hex"},  meta_arr);
    run_family("wrap");

    $readmemh({VEC_DIR, "/random_in.hex"},    in_arr);
    $readmemh({VEC_DIR, "/random_delta.hex"}, exp_arr);
    $readmemh({VEC_DIR, "/random_meta.hex"},  meta_arr);
    run_family("random");

    $readmemh({VEC_DIR, "/len1_in.hex"},    in_arr);
    $readmemh({VEC_DIR, "/len1_delta.hex"}, exp_arr);
    $readmemh({VEC_DIR, "/len1_meta.hex"},  meta_arr);
    run_family("len1");

    $display("PASS: tb_delta_enc");
    $finish;
  end

endmodule
