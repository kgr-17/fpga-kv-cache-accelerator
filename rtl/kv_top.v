`timescale 1ns/1ps
// kv_top.v — top level of the KV-cache optimizer demo (Digilent Basys 3).
// Wires uart_rx/uart_tx <-> proto_ctrl <-> {slice_mem, out_mem} and the
// compression pipeline engine_ctrl -> delta_enc -> rle_enc -> vec_buffer,
// plus stats_regs, ratio_calc, seg7_driver and io_sync.
// See docs/interfaces.md (FROZEN) for every submodule contract.

module kv_top #(
  parameter CLKS_PER_BIT    = 109,
  parameter WATCHDOG_CYCLES = 10_000_000
) (
  input  wire        clk,           // W5, 100 MHz
  input  wire        btnC,          // reset button
  input  wire        btnU,          // standalone re-run
  input  wire [15:0] sw,
  output wire [15:0] led,
  output wire [6:0]  seg,
  output wire [3:0]  an,
  input  wire        RsRx,
  output wire        RsTx
);

  // ------------------------------------------------------------------ reset
  // btnC through a 2-FF synchronizer plus a 16-cycle power-on reset shift
  // register. These registers ARE the reset source, so they rely on FPGA
  // configuration init values instead of the synchronous rst they generate.
  reg [15:0] por_sr    = 16'hffff;
  reg        btnc_meta = 1'b0;
  reg        btnc_sync = 1'b0;

  always @(posedge clk) begin
    por_sr    <= {por_sr[14:0], 1'b0};
    btnc_meta <= btnC;
    btnc_sync <= btnc_meta;
  end

  wire rst = por_sr[15] | btnc_sync;

  // ---------------------------------------------------------------- io_sync
  wire [15:0] sw_sync;
  wire        btn_run;

  io_sync u_io_sync (
    .clk         (clk),
    .rst         (rst),
    .i_sw        (sw),
    .o_sw        (sw_sync),
    .i_btnu      (btnU),
    .o_btnu_pulse(btn_run)
  );

  // ------------------------------------------------------------------- UART
  wire [7:0] rx_data;
  wire       rx_valid;
  wire [7:0] tx_data;
  wire       tx_valid, tx_ready;

  uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_rx (
    .clk    (clk),
    .rst    (rst),
    .i_rx   (RsRx),
    .o_data (rx_data),
    .o_valid(rx_valid)
  );

  uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_tx (
    .clk    (clk),
    .rst    (rst),
    .i_data (tx_data),
    .i_valid(tx_valid),
    .o_ready(tx_ready),
    .o_tx   (RsTx)
  );

  // ------------------------------------------------------------- proto_ctrl
  wire        ld_val_we;
  wire [14:0] ld_val_addr;
  wire [7:0]  ld_val_data;
  wire        ld_imp_we;
  wire [8:0]  ld_imp_addr;
  wire [7:0]  ld_imp_data;
  wire        run_start;
  wire [9:0]  cfg_entry_count;
  wire [6:0]  cfg_vec_len;
  wire [7:0]  run_threshold;
  wire        run_done, run_busy;
  wire [15:0] st_entries_in, st_entries_kept, st_bypass_cnt;
  wire [31:0] st_orig_bytes, st_comp_bytes, st_cycles;
  wire [15:0] rd_addr;
  wire [7:0]  rd_data;
  wire        slice_loaded;
  wire [3:0]  err_code;         // status code, not displayed on this board
  wire        err_pulse;
  // restore stream (v1.1 hardware decompressor)
  wire        rs_start, rs_valid, rs_ready, rs_active;
  wire [7:0]  rs_data;
  wire [15:0] rs_om_addr;

  proto_ctrl #(.WATCHDOG_CYCLES(WATCHDOG_CYCLES)) u_proto_ctrl (
    .clk            (clk),
    .rst            (rst),
    .rx_data        (rx_data),
    .rx_valid       (rx_valid),
    .tx_data        (tx_data),
    .tx_valid       (tx_valid),
    .tx_ready       (tx_ready),
    .ld_val_we      (ld_val_we),
    .ld_val_addr    (ld_val_addr),
    .ld_val_data    (ld_val_data),
    .ld_imp_we      (ld_imp_we),
    .ld_imp_addr    (ld_imp_addr),
    .ld_imp_data    (ld_imp_data),
    .run_start      (run_start),
    .cfg_entry_count(cfg_entry_count),
    .cfg_vec_len    (cfg_vec_len),
    .run_threshold  (run_threshold),
    .run_done       (run_done),
    .run_busy       (run_busy),
    .sw_threshold   (sw_sync[7:0]),
    .btn_run        (btn_run),
    .st_entries_in  (st_entries_in),
    .st_entries_kept(st_entries_kept),
    .st_orig_bytes  (st_orig_bytes),
    .st_comp_bytes  (st_comp_bytes),
    .st_bypass_cnt  (st_bypass_cnt),
    .st_cycles      (st_cycles),
    .rd_addr        (rd_addr),
    .rd_data        (rd_data),
    .rs_start       (rs_start),
    .rs_data        (rs_data),
    .rs_valid       (rs_valid),
    .rs_ready       (rs_ready),
    .slice_loaded   (slice_loaded),
    .err_code       (err_code),
    .err_pulse      (err_pulse)
  );

  // ----------------------------------------------------------------- memory
  wire [14:0] val_addr;
  wire [7:0]  val_data;
  wire [8:0]  imp_addr;
  wire [7:0]  imp_data;

  slice_mem u_slice_mem (
    .clk      (clk),
    .a_we     (ld_val_we),
    .a_addr   (ld_val_addr),
    .a_din    (ld_val_data),
    .b_addr   (val_addr),
    .b_dout   (val_data),
    .imp_we   (ld_imp_we),
    .imp_waddr(ld_imp_addr),
    .imp_din  (ld_imp_data),
    .imp_raddr(imp_addr),
    .imp_dout (imp_data)
  );

  wire        om_we;
  wire [15:0] om_addr;
  wire [7:0]  om_din;

  // port B shared: restore_ctrl owns it while a GET_RESTORED is streaming,
  // proto_ctrl's GET_DATA drain otherwise (the two are mutually exclusive)
  out_mem u_out_mem (
    .clk   (clk),
    .a_we  (om_we),
    .a_addr(om_addr),
    .a_din (om_din),
    .b_addr(rs_active ? rs_om_addr : rd_addr),
    .b_dout(rd_data)
  );

  restore_ctrl u_restore_ctrl (
    .clk          (clk),
    .rst          (rst),
    .i_start      (rs_start),
    .i_entry_count(cfg_entry_count),
    .i_vec_len    (cfg_vec_len),
    .o_active     (rs_active),
    .om_addr      (rs_om_addr),
    .om_data      (rd_data),
    .o_data       (rs_data),
    .o_valid      (rs_valid),
    .o_ready      (rs_ready),
    .o_done       ()
  );

  // --------------------------------------------------------------- pipeline
  // engine_ctrl.pipe_* -> delta_enc -> rle_enc -> vec_buffer (always ready).
  wire [7:0]  pipe_data;
  wire        pipe_valid, pipe_sov, pipe_eov, pipe_ready;
  wire [7:0]  d_data;
  wire        d_valid, d_eov, d_ready;
  wire [7:0]  r_data;
  wire        r_valid, r_last;
  wire [7:0]  vb_clen;
  wire        vb_done, vb_clr;
  wire [6:0]  vb_rd_addr;
  wire [7:0]  vb_rd_data;
  wire        eng_entry_inc, eng_kept_inc, eng_bypass_inc, eng_comp_set;
  wire [31:0] eng_comp_bytes;

  engine_ctrl u_engine_ctrl (
    .clk          (clk),
    .rst          (rst),
    .i_start      (run_start),
    .i_entry_count(cfg_entry_count),
    .i_vec_len    (cfg_vec_len),
    .i_thresh     (run_threshold),
    .o_busy       (run_busy),
    .o_done       (run_done),
    .val_addr     (val_addr),
    .val_data     (val_data),
    .imp_addr     (imp_addr),
    .imp_data     (imp_data),
    .pipe_data    (pipe_data),
    .pipe_valid   (pipe_valid),
    .pipe_sov     (pipe_sov),
    .pipe_eov     (pipe_eov),
    .pipe_ready   (pipe_ready),
    .vb_clen      (vb_clen),
    .vb_done      (vb_done),
    .vb_clr       (vb_clr),
    .vb_rd_addr   (vb_rd_addr),
    .vb_rd_data   (vb_rd_data),
    .om_we        (om_we),
    .om_addr      (om_addr),
    .om_din       (om_din),
    .st_entry_inc (eng_entry_inc),
    .st_kept_inc  (eng_kept_inc),
    .st_bypass_inc(eng_bypass_inc),
    .st_comp_set  (eng_comp_set),
    .st_comp_bytes(eng_comp_bytes)
  );

  delta_enc u_delta_enc (
    .clk    (clk),
    .rst    (rst),
    .i_data (pipe_data),
    .i_valid(pipe_valid),
    .i_sov  (pipe_sov),
    .i_eov  (pipe_eov),
    .i_ready(pipe_ready),
    .o_data (d_data),
    .o_valid(d_valid),
    .o_eov  (d_eov),
    .o_ready(d_ready)
  );

  rle_enc u_rle_enc (
    .clk    (clk),
    .rst    (rst),
    .i_data (d_data),
    .i_valid(d_valid),
    .i_eov  (d_eov),
    .i_ready(d_ready),
    .o_data (r_data),
    .o_valid(r_valid),
    .o_last (r_last),
    .o_ready(1'b1)               // vec_buffer is always ready
  );

  vec_buffer u_vec_buffer (
    .clk    (clk),
    .rst    (rst),
    .clr    (vb_clr),
    .i_data (r_data),
    .i_valid(r_valid),
    .i_last (r_last),
    .o_clen (vb_clen),
    .done   (vb_done),
    .rd_addr(vb_rd_addr),
    .rd_data(vb_rd_data)
  );

  // ------------------------------------------------------------------ stats
  stats_regs u_stats_regs (
    .clk          (clk),
    .rst          (rst),
    .clr          (run_start),
    .cyc_en       (run_busy),
    .entry_inc    (eng_entry_inc),
    .kept_inc     (eng_kept_inc),
    .bypass_inc   (eng_bypass_inc),
    .vec_len      (cfg_vec_len),
    .comp_set     (eng_comp_set),
    .comp_bytes_in(eng_comp_bytes),
    .entries_in   (st_entries_in),
    .entries_kept (st_entries_kept),
    .bypass_cnt   (st_bypass_cnt),
    .orig_bytes   (st_orig_bytes),
    .comp_bytes   (st_comp_bytes),
    .cycles       (st_cycles)
  );

  wire [15:0] ratio_x100;
  wire        ratio_done;        // display-only divider, completion unused

  ratio_calc u_ratio_calc (
    .clk       (clk),
    .rst       (rst),
    .start     (run_done),
    .num       (st_orig_bytes),
    .den       (st_comp_bytes),
    .ratio_x100(ratio_x100),
    .done      (ratio_done)
  );

  // ---------------------------------------------------------------- display
  // 7-seg source select by SW[15:14]:
  //   00 ratio_x100, 01 entries_kept, 10 comp_bytes>>4, 11 cycles>>10.
  reg [15:0] seg_value;

  always @* begin
    case (sw_sync[15:14])
      2'b00:   seg_value = ratio_x100;
      2'b01:   seg_value = st_entries_kept;
      2'b10:   seg_value = st_comp_bytes[19:4];
      default: seg_value = st_cycles[25:10];
    endcase
  end

  seg7_driver u_seg7_driver (
    .clk    (clk),
    .rst    (rst),
    .i_value(seg_value),
    .o_seg  (seg),
    .o_an   (an)
  );

  // ------------------------------------------------------------------- LEDs
  // Activity strobes are stretched to ~10 ms (1,000,000 cycles at 100 MHz)
  // so they are visible on the board.
  localparam [19:0] ACT_STRETCH = 20'd1_000_000;

  reg [19:0] rx_act_cnt, tx_act_cnt, err_act_cnt;

  always @(posedge clk) begin
    if (rst) begin
      rx_act_cnt  <= 20'd0;
      tx_act_cnt  <= 20'd0;
      err_act_cnt <= 20'd0;
    end else begin
      if (rx_valid)                rx_act_cnt  <= ACT_STRETCH;
      else if (rx_act_cnt != 0)    rx_act_cnt  <= rx_act_cnt - 20'd1;
      if (tx_valid && tx_ready)    tx_act_cnt  <= ACT_STRETCH;
      else if (tx_act_cnt != 0)    tx_act_cnt  <= tx_act_cnt - 20'd1;
      if (err_pulse)               err_act_cnt <= ACT_STRETCH;
      else if (err_act_cnt != 0)   err_act_cnt <= err_act_cnt - 20'd1;
    end
  end

  assign led[0]    = (rx_act_cnt  != 20'd0);   // RX activity
  assign led[1]    = run_busy;                 // engine busy
  assign led[2]    = (tx_act_cnt  != 20'd0);   // TX activity
  assign led[3]    = slice_loaded;
  assign led[4]    = (err_act_cnt != 20'd0);   // error
  assign led[7:5]  = 3'b000;
  assign led[15:8] = sw_sync[7:0];             // threshold echo

endmodule
