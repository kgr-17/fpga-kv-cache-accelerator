// tb_units: directed self-checking tests for ratio_calc and stats_regs.
// Pure Verilog-2001. Prints exactly one "PASS: tb_units" on success, or
// "FAIL: tb_units <reason>" and finishes on the first mismatch.
`timescale 1ns/1ps

module tb_units;

  // Convention parameter (no vector files are needed for these directed tests).
  parameter VEC_DIR = "../../../../sim/vectors";

  reg clk;
  reg rst;

  // ratio_calc DUT signals
  reg         rc_start;
  reg  [31:0] rc_num, rc_den;
  wire [15:0] rc_ratio;
  wire        rc_done;

  // stats_regs DUT signals
  reg         st_clr, st_cyc_en, st_entry_inc, st_kept_inc, st_bypass_inc, st_comp_set;
  reg  [6:0]  st_vec_len;
  reg  [31:0] st_comp_bytes_in;
  wire [15:0] st_entries_in, st_entries_kept, st_bypass_cnt;
  wire [31:0] st_orig_bytes, st_comp_bytes, st_cycles;

  integer i;

  ratio_calc u_ratio (
    .clk(clk), .rst(rst),
    .start(rc_start), .num(rc_num), .den(rc_den),
    .ratio_x100(rc_ratio), .done(rc_done)
  );

  stats_regs u_stats (
    .clk(clk), .rst(rst),
    .clr(st_clr), .cyc_en(st_cyc_en),
    .entry_inc(st_entry_inc), .kept_inc(st_kept_inc), .bypass_inc(st_bypass_inc),
    .vec_len(st_vec_len),
    .comp_set(st_comp_set), .comp_bytes_in(st_comp_bytes_in),
    .entries_in(st_entries_in), .entries_kept(st_entries_kept),
    .bypass_cnt(st_bypass_cnt),
    .orig_bytes(st_orig_bytes), .comp_bytes(st_comp_bytes), .cycles(st_cycles)
  );

  // 100 MHz clock
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // Global timeout watchdog
  initial begin
    #200_000_000;
    $display("FAIL: tb_units global timeout");
    $finish;
  end

  // Run one ratio_calc case: pulse start, wait for done, check value and that
  // done is a 1-cycle strobe. All stimulus/sampling on negedge.
  task test_ratio;
    input [31:0] t_num, t_den;
    input [15:0] t_exp;
    integer w;
    begin
      @(negedge clk);
      rc_num   = t_num;
      rc_den   = t_den;
      rc_start = 1'b1;
      @(negedge clk);
      rc_start = 1'b0;
      w = 0;
      while (rc_done !== 1'b1 && w < 200) begin
        @(negedge clk);
        w = w + 1;
      end
      if (rc_done !== 1'b1) begin
        $display("FAIL: tb_units ratio_calc no done pulse (num=%0d den=%0d)", t_num, t_den);
        $finish;
      end
      if (rc_ratio !== t_exp) begin
        $display("FAIL: tb_units ratio_calc num=%0d den=%0d got %0d expected %0d",
                 t_num, t_den, rc_ratio, t_exp);
        $finish;
      end
      @(negedge clk);
      if (rc_done !== 1'b0) begin
        $display("FAIL: tb_units ratio_calc done not a 1-cycle strobe (num=%0d den=%0d)",
                 t_num, t_den);
        $finish;
      end
    end
  endtask

  initial begin
    // init
    rst              = 1'b1;
    rc_start         = 1'b0;
    rc_num           = 32'd0;
    rc_den           = 32'd0;
    st_clr           = 1'b0;
    st_cyc_en        = 1'b0;
    st_entry_inc     = 1'b0;
    st_kept_inc      = 1'b0;
    st_bypass_inc    = 1'b0;
    st_comp_set      = 1'b0;
    st_vec_len       = 7'd0;
    st_comp_bytes_in = 32'd0;
    repeat (4) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // ---------------- ratio_calc directed cases ----------------
    test_ratio(32'd64,    32'd42,    16'd152);   // 6400/42
    test_ratio(32'd64,    32'd64,    16'd100);
    test_ratio(32'd512,   32'd2,     16'd9999);  // 25600 -> saturate
    test_ratio(32'd100,   32'd0,     16'd0);     // div by zero -> 0
    test_ratio(32'd33344, 32'd33344, 16'd100);
    test_ratio(32'd32768, 32'd10432, 16'd314);

    // ---------------- stats_regs ----------------
    // Dirty a few counters, then clr and verify everything is zeroed.
    @(negedge clk);
    st_vec_len   = 7'd13;
    st_entry_inc = 1'b1;
    st_kept_inc  = 1'b1;
    @(negedge clk);
    st_entry_inc = 1'b0;
    st_kept_inc  = 1'b0;
    @(negedge clk);
    st_clr = 1'b1;
    @(negedge clk);
    st_clr = 1'b0;
    @(negedge clk);
    if (st_entries_in !== 16'd0 || st_entries_kept !== 16'd0 || st_bypass_cnt !== 16'd0 ||
        st_orig_bytes !== 32'd0 || st_comp_bytes !== 32'd0 || st_cycles !== 32'd0) begin
      $display("FAIL: tb_units stats_regs clr did not zero all counters");
      $finish;
    end

    // 5 entry_inc strobes with vec_len = 8
    st_vec_len = 7'd8;
    for (i = 0; i < 5; i = i + 1) begin
      @(negedge clk);
      st_entry_inc = 1'b1;
      @(negedge clk);
      st_entry_inc = 1'b0;
    end
    @(negedge clk);
    if (st_entries_in !== 16'd5) begin
      $display("FAIL: tb_units stats_regs entries_in got %0d expected 5", st_entries_in);
      $finish;
    end
    if (st_orig_bytes !== 32'd40) begin
      $display("FAIL: tb_units stats_regs orig_bytes got %0d expected 40", st_orig_bytes);
      $finish;
    end

    // 3 kept_inc strobes, 1 bypass_inc strobe
    for (i = 0; i < 3; i = i + 1) begin
      @(negedge clk);
      st_kept_inc = 1'b1;
      @(negedge clk);
      st_kept_inc = 1'b0;
    end
    @(negedge clk);
    st_bypass_inc = 1'b1;
    @(negedge clk);
    st_bypass_inc = 1'b0;
    @(negedge clk);
    if (st_entries_kept !== 16'd3) begin
      $display("FAIL: tb_units stats_regs entries_kept got %0d expected 3", st_entries_kept);
      $finish;
    end
    if (st_bypass_cnt !== 16'd1) begin
      $display("FAIL: tb_units stats_regs bypass_cnt got %0d expected 1", st_bypass_cnt);
      $finish;
    end

    // cyc_en high for exactly 100 clock cycles (100 posedges see it high)
    if (st_cycles !== 32'd0) begin
      $display("FAIL: tb_units stats_regs cycles nonzero before cyc_en test");
      $finish;
    end
    @(negedge clk);
    st_cyc_en = 1'b1;
    repeat (100) @(negedge clk);
    st_cyc_en = 1'b0;
    @(negedge clk);
    if (st_cycles !== 32'd100) begin
      $display("FAIL: tb_units stats_regs cycles got %0d expected 100", st_cycles);
      $finish;
    end

    // comp_set with 12345
    @(negedge clk);
    st_comp_bytes_in = 32'd12345;
    st_comp_set      = 1'b1;
    @(negedge clk);
    st_comp_set = 1'b0;
    @(negedge clk);
    if (st_comp_bytes !== 32'd12345) begin
      $display("FAIL: tb_units stats_regs comp_bytes got %0d expected 12345", st_comp_bytes);
      $finish;
    end

    // Final consistency check: earlier counters must be untouched by later strobes.
    if (st_entries_in !== 16'd5 || st_entries_kept !== 16'd3 || st_bypass_cnt !== 16'd1 ||
        st_orig_bytes !== 32'd40 || st_cycles !== 32'd100) begin
      $display("FAIL: tb_units stats_regs counters corrupted by unrelated strobes");
      $finish;
    end

    $display("PASS: tb_units");
    $finish;
  end

endmodule
