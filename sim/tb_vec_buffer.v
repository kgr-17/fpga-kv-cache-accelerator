// tb_vec_buffer: directed self-checking TB for vec_buffer, plus a combinational
// sanity check of evict_filter. Pure Verilog-2001.
`timescale 1ns/1ps

module tb_vec_buffer;

  parameter VEC_DIR = "../../../../sim/vectors";

  reg        clk;
  reg        rst;
  reg        clr;
  reg  [7:0] i_data;
  reg        i_valid;
  reg        i_last;
  wire [7:0] o_clen;
  wire       done;
  reg  [6:0] rd_addr;
  wire [7:0] rd_data;

  vec_buffer dut (
    .clk     (clk),
    .rst     (rst),
    .clr     (clr),
    .i_data  (i_data),
    .i_valid (i_valid),
    .i_last  (i_last),
    .o_clen  (o_clen),
    .done    (done),
    .rd_addr (rd_addr),
    .rd_data (rd_data)
  );

  reg  [7:0] ef_imp;
  reg  [7:0] ef_thresh;
  wire       ef_keep;

  evict_filter u_ef (
    .i_imp    (ef_imp),
    .i_thresh (ef_thresh),
    .o_keep   (ef_keep)
  );

  // Stimulus bytes (arbitrary data; distinct offsets per test).
  reg [7:0] vec_data [0:1023];

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // Global timeout watchdog.
  initial begin
    #200_000_000;
    $display("FAIL: tb_vec_buffer timeout");
    $finish;
  end

  // Count done pulses. Sampling on posedge sees each 1-cycle strobe exactly
  // once (at the edge that ends the done cycle); a wide or spurious pulse
  // shows up as a wrong cumulative count.
  integer done_count;
  initial done_count = 0;
  always @(posedge clk) if (done) done_count = done_count + 1;

  // Drive one input byte for exactly one clock (call back-to-back for a
  // gapless stream). Also drops clr so a byte can directly follow a clr cycle.
  task send_byte;
    input [7:0] b;
    input       last_f;
    begin
      @(negedge clk);
      clr     = 1'b0;
      i_valid = 1'b1;
      i_data  = b;
      i_last  = last_f;
    end
  endtask

  // One idle cycle on the stream inputs.
  task idle_cycle;
    begin
      @(negedge clk);
      clr     = 1'b0;
      i_valid = 1'b0;
      i_last  = 1'b0;
    end
  endtask

  // Assert clr for the cycle immediately after the previous byte; the next
  // send_byte deasserts it, so vectors are separated by exactly one clr cycle.
  task assert_clr;
    begin
      @(negedge clk);
      clr     = 1'b1;
      i_valid = 1'b0;
      i_last  = 1'b0;
    end
  endtask

  // Called mid-cycle right after the i_last byte was clocked in: done must be
  // high now (this is its single strobe cycle) with the expected byte count.
  task check_done;
    input [7:0] exp_clen;
    begin
      if (done !== 1'b1) begin
        $display("FAIL: tb_vec_buffer done not asserted (exp clen=%0d)", exp_clen);
        $finish;
      end
      if (o_clen !== exp_clen) begin
        $display("FAIL: tb_vec_buffer o_clen=%0d expected %0d", o_clen, exp_clen);
        $finish;
      end
    end
  endtask

  // Advance one cycle past the done strobe: done must have dropped and the
  // cumulative pulse count must match (catches multi-cycle/spurious pulses).
  task check_strobe_end;
    input integer exp_count;
    begin
      @(negedge clk);
      if (done !== 1'b0) begin
        $display("FAIL: tb_vec_buffer done wider than 1 cycle");
        $finish;
      end
      if (done_count !== exp_count) begin
        $display("FAIL: tb_vec_buffer done_count=%0d expected %0d",
                 done_count, exp_count);
        $finish;
      end
    end
  endtask

  // Async readback of len bytes against vec_data[off..off+len-1].
  task check_read;
    input integer off;
    input integer len;
    integer a;
    begin
      for (a = 0; a < len; a = a + 1) begin
        rd_addr = a[6:0];
        #1;
        if (rd_data !== vec_data[off + a]) begin
          $display("FAIL: tb_vec_buffer readback addr=%0d got=%02x exp=%02x",
                   a, rd_data, vec_data[off + a]);
          $finish;
        end
      end
    end
  endtask

  // evict_filter combinational check: keep iff imp >= thresh (unsigned).
  task check_ef;
    input [7:0] imp;
    input [7:0] th;
    input       exp_keep;
    begin
      ef_imp    = imp;
      ef_thresh = th;
      #1;
      if (ef_keep !== exp_keep) begin
        $display("FAIL: tb_vec_buffer evict_filter imp=%0d thresh=%0d keep=%b exp=%b",
                 imp, th, ef_keep, exp_keep);
        $finish;
      end
    end
  endtask

  integer k;

  initial begin
    $readmemh({VEC_DIR, "/random_in.hex"}, vec_data);

    rst       = 1'b1;
    clr       = 1'b0;
    i_data    = 8'h00;
    i_valid   = 1'b0;
    i_last    = 1'b0;
    rd_addr   = 7'd0;
    ef_imp    = 8'h00;
    ef_thresh = 8'h00;
    repeat (4) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // evict_filter sanity: equal values keep, extremes, unsigned compare.
    check_ef(8'd0,   8'd0,   1'b1);  // equal -> keep
    check_ef(8'd5,   8'd5,   1'b1);  // equal -> keep
    check_ef(8'd255, 8'd255, 1'b1);  // equal -> keep
    check_ef(8'd4,   8'd5,   1'b0);
    check_ef(8'd6,   8'd5,   1'b1);
    check_ef(8'd0,   8'd1,   1'b0);
    check_ef(8'd255, 8'd0,   1'b1);
    check_ef(8'd0,   8'd255, 1'b0);
    check_ef(8'd254, 8'd255, 1'b0);
    check_ef(8'd128, 8'd127, 1'b1);  // fails if compare were signed
    check_ef(8'd127, 8'd128, 1'b0);

    // (a) 3 bytes, last on 3rd: done pulses once, clen==3, readback matches.
    for (k = 0; k < 3; k = k + 1)
      send_byte(vec_data[k], k == 2);
    idle_cycle;                    // done strobe cycle
    check_done(8'd3);
    check_strobe_end(1);
    check_read(0, 3);

    // (b) clr, then a 96-byte vector (max legal clen): clen==96, full readback.
    assert_clr;
    for (k = 0; k < 96; k = k + 1)
      send_byte(vec_data[100 + k], k == 95);
    idle_cycle;
    check_done(8'd96);
    check_strobe_end(2);
    check_read(100, 96);

    // (c) two back-to-back vectors separated only by a single clr cycle.
    assert_clr;
    for (k = 0; k < 5; k = k + 1)
      send_byte(vec_data[200 + k], k == 4);
    assert_clr;                    // vec1 done strobe cycle == clr cycle
    check_done(8'd5);
    for (k = 0; k < 4; k = k + 1)  // first byte lands the cycle after clr
      send_byte(vec_data[300 + k], k == 3);
    idle_cycle;
    check_done(8'd4);
    check_strobe_end(4);           // vec1 + vec2 pulses both counted
    check_read(300, 4);

    // (d) single-byte vector, i_last on the first byte: clen==1.
    assert_clr;
    send_byte(vec_data[400], 1'b1);
    idle_cycle;
    check_done(8'd1);
    check_strobe_end(5);
    check_read(400, 1);

    $display("PASS: tb_vec_buffer");
    $finish;
  end

endmodule
