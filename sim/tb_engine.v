// tb_engine.v -- self-checking testbench for the full compression engine:
// engine_ctrl + slice_mem + delta_enc -> rle_enc -> vec_buffer + out_mem + stats_regs.
// Preloads slice memories hierarchically, runs one pass, then checks out_mem contents
// against eng_expected.hex and stats against eng_stats.hex.
`timescale 1ns/1ps

module tb_engine;

  parameter VEC_DIR = "../../../../sim/vectors";

  reg clk;
  reg rst;
  reg start;
  reg stats_clr;

  // parameters loaded from eng_params.hex
  reg [15:0] ec;   // entry_count
  reg [6:0]  vl;   // vec_len
  reg [7:0]  th;   // threshold

  // engine <-> memories / pipeline wiring
  wire        busy, done;
  wire [14:0] val_addr;
  wire [7:0]  val_data;
  wire [8:0]  imp_addr;
  wire [7:0]  imp_data;
  wire [7:0]  pipe_data;
  wire        pipe_valid, pipe_sov, pipe_eov, pipe_ready;
  wire [7:0]  vb_clen;
  wire        vb_done, vb_clr;
  wire [6:0]  vb_rd_addr;
  wire [7:0]  vb_rd_data;
  wire        om_we;
  wire [15:0] om_addr;
  wire [7:0]  om_din;
  wire        st_entry_inc, st_kept_inc, st_bypass_inc, st_comp_set;
  wire [31:0] st_comp_bytes;

  // delta_enc -> rle_enc
  wire [7:0]  d2r_data;
  wire        d2r_valid, d2r_eov, d2r_ready;
  // rle_enc -> vec_buffer
  wire [7:0]  r2v_data;
  wire        r2v_valid, r2v_last;

  wire [7:0]  om_b_dout;

  // stats outputs
  wire [15:0] s_entries_in, s_entries_kept, s_bypass_cnt;
  wire [31:0] s_orig_bytes, s_comp_bytes, s_cycles;

  // vector storage
  reg [7:0] params [0:3];
  reg [7:0] statsb [0:12];
  reg [7:0] expct  [0:36863];

  reg [15:0] exp_kept, exp_byp;
  reg [31:0] exp_orig, exp_comp;

  integer i;
  reg [7:0] got;

  slice_mem u_slice (
    .clk       (clk),
    .a_we      (1'b0),
    .a_addr    (15'd0),
    .a_din     (8'd0),
    .b_addr    (val_addr),
    .b_dout    (val_data),
    .imp_we    (1'b0),
    .imp_waddr (9'd0),
    .imp_din   (8'd0),
    .imp_raddr (imp_addr),
    .imp_dout  (imp_data)
  );

  out_mem u_out (
    .clk    (clk),
    .a_we   (om_we),
    .a_addr (om_addr),
    .a_din  (om_din),
    .b_addr (16'd0),
    .b_dout (om_b_dout)
  );

  delta_enc u_delta (
    .clk     (clk),
    .rst     (rst),
    .i_data  (pipe_data),
    .i_valid (pipe_valid),
    .i_sov   (pipe_sov),
    .i_eov   (pipe_eov),
    .i_ready (pipe_ready),
    .o_data  (d2r_data),
    .o_valid (d2r_valid),
    .o_eov   (d2r_eov),
    .o_ready (d2r_ready)
  );

  rle_enc u_rle (
    .clk     (clk),
    .rst     (rst),
    .i_data  (d2r_data),
    .i_valid (d2r_valid),
    .i_eov   (d2r_eov),
    .i_ready (d2r_ready),
    .o_data  (r2v_data),
    .o_valid (r2v_valid),
    .o_last  (r2v_last),
    .o_ready (1'b1)          // vec_buffer is always ready
  );

  vec_buffer u_vb (
    .clk     (clk),
    .rst     (rst),
    .clr     (vb_clr),
    .i_data  (r2v_data),
    .i_valid (r2v_valid),
    .i_last  (r2v_last),
    .o_clen  (vb_clen),
    .done    (vb_done),
    .rd_addr (vb_rd_addr),
    .rd_data (vb_rd_data)
  );

  stats_regs u_stats (
    .clk           (clk),
    .rst           (rst),
    .clr           (stats_clr),
    .cyc_en        (busy),
    .entry_inc     (st_entry_inc),
    .kept_inc      (st_kept_inc),
    .bypass_inc    (st_bypass_inc),
    .vec_len       (vl),
    .comp_set      (st_comp_set),
    .comp_bytes_in (st_comp_bytes),
    .entries_in    (s_entries_in),
    .entries_kept  (s_entries_kept),
    .bypass_cnt    (s_bypass_cnt),
    .orig_bytes    (s_orig_bytes),
    .comp_bytes    (s_comp_bytes),
    .cycles        (s_cycles)
  );

  engine_ctrl u_eng (
    .clk           (clk),
    .rst           (rst),
    .i_start       (start),
    .i_entry_count (ec[9:0]),
    .i_vec_len     (vl),
    .i_thresh      (th),
    .o_busy        (busy),
    .o_done        (done),
    .val_addr      (val_addr),
    .val_data      (val_data),
    .imp_addr      (imp_addr),
    .imp_data      (imp_data),
    .pipe_data     (pipe_data),
    .pipe_valid    (pipe_valid),
    .pipe_sov      (pipe_sov),
    .pipe_eov      (pipe_eov),
    .pipe_ready    (pipe_ready),
    .vb_clen       (vb_clen),
    .vb_done       (vb_done),
    .vb_clr        (vb_clr),
    .vb_rd_addr    (vb_rd_addr),
    .vb_rd_data    (vb_rd_data),
    .om_we         (om_we),
    .om_addr       (om_addr),
    .om_din        (om_din),
    .st_entry_inc  (st_entry_inc),
    .st_kept_inc   (st_kept_inc),
    .st_bypass_inc (st_bypass_inc),
    .st_comp_set   (st_comp_set),
    .st_comp_bytes (st_comp_bytes)
  );

  // 100 MHz clock
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // global timeout watchdog
  initial begin
    #200_000_000;
    $display("FAIL: tb_engine global timeout");
    $finish;
  end

  initial begin
    rst       = 1'b1;
    start     = 1'b0;
    stats_clr = 1'b0;
    ec        = 16'd0;
    vl        = 7'd0;
    th        = 8'd0;

    // load vectors and preload memories hierarchically
    $readmemh({VEC_DIR, "/eng_values.hex"},   u_slice.mem);
    $readmemh({VEC_DIR, "/eng_imp.hex"},      u_slice.imp_mem);
    $readmemh({VEC_DIR, "/eng_params.hex"},   params);
    $readmemh({VEC_DIR, "/eng_expected.hex"}, expct);
    $readmemh({VEC_DIR, "/eng_stats.hex"},    statsb);

    ec = {params[1], params[0]};
    vl = params[2][6:0];
    th = params[3];

    exp_kept = {statsb[1],  statsb[0]};
    exp_orig = {statsb[5],  statsb[4], statsb[3], statsb[2]};
    exp_comp = {statsb[9],  statsb[8], statsb[7], statsb[6]};
    exp_byp  = {statsb[11], statsb[10]};

    // reset
    repeat (5) @(posedge clk);
    rst <= 1'b0;
    repeat (2) @(posedge clk);

    // clear stats, then start the engine
    stats_clr <= 1'b1;
    @(posedge clk);
    stats_clr <= 1'b0;
    @(posedge clk);
    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;

    // wait for completion (global watchdog bounds this)
    wait (done === 1'b1);
    repeat (4) @(posedge clk);

    // check 1: out_mem contents vs eng_expected.hex
    for (i = 0; i < exp_comp; i = i + 1) begin
      got = u_out.mem[i];
      if (got !== expct[i]) begin
        $display("FAIL: tb_engine out_mem[%0d] got %02h expected %02h", i, got, expct[i]);
        $finish;
      end
    end

    // check 2: stats
    if (s_entries_in !== ec) begin
      $display("FAIL: tb_engine entries_in got %0d expected %0d", s_entries_in, ec);
      $finish;
    end
    if (s_entries_kept !== exp_kept) begin
      $display("FAIL: tb_engine entries_kept got %0d expected %0d", s_entries_kept, exp_kept);
      $finish;
    end
    if (s_orig_bytes !== exp_orig) begin
      $display("FAIL: tb_engine orig_bytes got %0d expected %0d", s_orig_bytes, exp_orig);
      $finish;
    end
    if (s_comp_bytes !== exp_comp) begin
      $display("FAIL: tb_engine comp_bytes got %0d expected %0d", s_comp_bytes, exp_comp);
      $finish;
    end
    if (s_bypass_cnt !== exp_byp) begin
      $display("FAIL: tb_engine bypass_cnt got %0d expected %0d", s_bypass_cnt, exp_byp);
      $finish;
    end

    // check 3: cycle count plausibility
    if (!(s_cycles > 32'd0 && s_cycles < 32'd100000)) begin
      $display("FAIL: tb_engine cycles implausible got %0d", s_cycles);
      $finish;
    end

    // printed so the hardware stats record can be compared against sim
    // (identical slice + threshold must give an identical PROCESS cycle count)
    $display("tb_engine cycles_process = %0d", s_cycles);
    $display("PASS: tb_engine");
    $finish;
  end

endmodule
