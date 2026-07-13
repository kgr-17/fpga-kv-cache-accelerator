// proto_ctrl.v -- UART protocol FSM per docs/protocol.md and docs/interfaces.md.
// One FSM covers RX framing, command dispatch, run sequencing and response
// streaming. Store-and-forward: RX bytes arriving while a response is being
// sent or a run is in flight are ignored (host is strictly request/response).
module proto_ctrl #(parameter WATCHDOG_CYCLES = 10_000_000) (
  input  wire        clk,
  input  wire        rst,
  // UART
  input  wire [7:0]  rx_data,
  input  wire        rx_valid,
  output reg  [7:0]  tx_data,
  output reg         tx_valid,
  input  wire        tx_ready,
  // slice load (write-through during LOAD_SLICE payload reception)
  output reg         ld_val_we,
  output reg  [14:0] ld_val_addr,
  output reg  [7:0]  ld_val_data,
  output reg         ld_imp_we,
  output reg  [8:0]  ld_imp_addr,
  output reg  [7:0]  ld_imp_data,
  // run control (single owner of run_start and threshold_used)
  output reg         run_start,
  output reg  [9:0]  cfg_entry_count,
  output reg  [6:0]  cfg_vec_len,
  output reg  [7:0]  run_threshold,
  input  wire        run_done,
  input  wire        run_busy,
  input  wire [7:0]  sw_threshold,
  input  wire        btn_run,
  // stats (valid after run_done)
  input  wire [15:0] st_entries_in,
  input  wire [15:0] st_entries_kept,
  input  wire [31:0] st_orig_bytes,
  input  wire [31:0] st_comp_bytes,
  input  wire [15:0] st_bypass_cnt,
  input  wire [31:0] st_cycles,
  // out_mem read (synchronous: rd_data valid 1 cycle after rd_addr)
  output reg  [15:0] rd_addr,
  input  wire [7:0]  rd_data,
  // restore stream (v1.1: GET_RESTORED payload source, from restore_ctrl)
  output reg         rs_start,
  input  wire [7:0]  rs_data,
  input  wire        rs_valid,
  output wire        rs_ready,
  // status
  output reg         slice_loaded,
  output reg  [3:0]  err_code,
  output reg         err_pulse
);

  // framing / command constants
  localparam [7:0] SOF_HOST  = 8'hA5;
  localparam [7:0] SOF_DEV   = 8'h5A;
  localparam [7:0] CMD_PING  = 8'h01;
  localparam [7:0] CMD_LOAD  = 8'h10;
  localparam [7:0] CMD_RUN   = 8'h20;
  localparam [7:0] CMD_STATS = 8'h30;
  localparam [7:0] CMD_DATA  = 8'h40;
  localparam [7:0] CMD_RSTR  = 8'h50;
  localparam [7:0] ERR_CKSUM     = 8'h01;
  localparam [7:0] ERR_MALFORMED = 8'h02;
  localparam [7:0] ERR_NO_SLICE  = 8'h03;
  localparam [7:0] ERR_UNKNOWN   = 8'h04;

  // FSM states
  localparam [4:0] S_IDLE   = 5'd0;   // hunt for SOF; accept btn_run
  localparam [4:0] S_CMD    = 5'd1;
  localparam [4:0] S_LEN_LO = 5'd2;
  localparam [4:0] S_LEN_HI = 5'd3;
  localparam [4:0] S_PAY    = 5'd4;
  localparam [4:0] S_CKSUM  = 5'd5;
  localparam [4:0] S_DISP   = 5'd6;   // full frame consumed: decide action/response
  localparam [4:0] S_RUN_GO = 5'd7;   // wait engine idle, pulse run_start
  localparam [4:0] S_RUN_WT = 5'd8;   // wait run_done
  localparam [4:0] S_T_SOF  = 5'd9;
  localparam [4:0] S_T_CMD  = 5'd10;
  localparam [4:0] S_T_LENL = 5'd11;
  localparam [4:0] S_T_LENH = 5'd12;
  localparam [4:0] S_T_PAY  = 5'd13;  // register-sourced payload byte
  localparam [4:0] S_T_DADR = 5'd14;  // GET_DATA: issue out_mem address
  localparam [4:0] S_T_DWT  = 5'd15;  // GET_DATA: BRAM output-register latency
  localparam [4:0] S_T_DSND = 5'd16;  // GET_DATA: send fetched byte
  localparam [4:0] S_T_CKS  = 5'd17;
  localparam [4:0] S_T_RSND = 5'd18;  // GET_RESTORED: consume restore stream byte

  // response payload sources
  localparam [2:0] K_ERR = 3'd0, K_PING = 3'd1, K_LOAD = 3'd2,
                   K_STATS = 3'd3, K_DATA = 3'd4, K_RSTR = 3'd5;

  reg [4:0]  state;
  reg [7:0]  cmd;
  reg [15:0] len;
  reg [7:0]  cksum_rx;   // running sum of CMD + LEN + PAYLOAD + CKSUM (mod 256)
  reg [15:0] pay_cnt;
  // LOAD_SLICE header parse / write-through position
  reg [15:0] ld_count;   // raw entry_count from header
  reg [7:0]  ld_vlen;    // raw vec_len from header
  reg        load_ok;    // header valid this frame -> write-through enabled
  reg [9:0]  entry_i;
  reg [6:0]  byte_j;     // 0 = importance byte, 1..vec_len = value bytes
  // RUN payload
  reg [7:0]  run_mode, run_thr_pl;
  reg        is_btn;     // current run was button-triggered (no response frame)
  reg        had_run;    // a run completed since the last LOAD (gates GET_STATS/GET_DATA)
  // response descriptor
  reg [7:0]  resp_cmd;
  reg [15:0] resp_len;
  reg [2:0]  resp_kind;
  reg [7:0]  resp_err;
  reg [7:0]  cksum_tx;   // accumulated while streaming (CMD + LEN + PAYLOAD)
  reg [15:0] pay_idx;
  // watchdog
  reg [31:0] wd_cnt;

  wire in_rx_frame = (state == S_CMD) || (state == S_LEN_LO) ||
                     (state == S_LEN_HI) || (state == S_PAY) || (state == S_CKSUM);

  // LOAD header validation: LEN must equal 4 + entry_count*(1+vec_len).
  // 18-bit arithmetic: max out-of-range product 1023*256 still fits, no overflow.
  wire        range_ok = (ld_count != 16'd0) && (ld_count <= 16'd512) &&
                         (ld_vlen  != 8'd0)  && (ld_vlen  <= 8'd64);
  wire [17:0] exp_len  = ld_count[9:0] * (ld_vlen + 8'd1) + 18'd4;
  wire        hdr_ok   = range_ok && ({2'b00, len} == exp_len);

  wire [6:0]  jm1 = byte_j - 7'd1;   // value byte index j (byte_j = j+1)

  // GET_RESTORED response length: bitmap + kept*vec_len (max 64 + 32768, fits 16b)
  wire [6:0]  bm_len_p = (cfg_entry_count + 10'd7) >> 3;
  wire [16:0] rs_len   = {10'd0, bm_len_p} +
                         (st_entries_kept[9:0] * {10'd0, cfg_vec_len});

  // restore byte is consumed the cycle it is latched into tx_data
  assign rs_ready = (state == S_T_RSND) && !tx_valid;

  // response payload byte mux (GET_DATA bytes come from rd_data instead)
  reg [7:0] resp_byte;
  always @* begin
    resp_byte = 8'h00;
    case (resp_kind)
      K_ERR: resp_byte = resp_err;
      K_PING:
        case (pay_idx[1:0])
          2'd0: resp_byte = 8'd1;      // ver_major
          2'd1: resp_byte = 8'd1;      // ver_minor (1.1: GET_RESTORED)
          2'd2: resp_byte = 8'h00;     // max_entries = 512 LE
          2'd3: resp_byte = 8'h02;
        endcase
      K_LOAD:
        case (pay_idx[1:0])
          2'd0: resp_byte = cfg_entry_count[7:0];          // entries_stored LE
          2'd1: resp_byte = {6'd0, cfg_entry_count[9:8]};
          default: resp_byte = 8'h00;                      // status = 0
        endcase
      K_STATS:
        case (pay_idx[4:0])
          5'd0:  resp_byte = 8'h00;                        // status = 0
          5'd1:  resp_byte = st_entries_in[7:0];
          5'd2:  resp_byte = st_entries_in[15:8];
          5'd3:  resp_byte = st_entries_kept[7:0];
          5'd4:  resp_byte = st_entries_kept[15:8];
          5'd5:  resp_byte = st_orig_bytes[7:0];
          5'd6:  resp_byte = st_orig_bytes[15:8];
          5'd7:  resp_byte = st_orig_bytes[23:16];
          5'd8:  resp_byte = st_orig_bytes[31:24];
          5'd9:  resp_byte = st_comp_bytes[7:0];
          5'd10: resp_byte = st_comp_bytes[15:8];
          5'd11: resp_byte = st_comp_bytes[23:16];
          5'd12: resp_byte = st_comp_bytes[31:24];
          5'd13: resp_byte = st_bypass_cnt[7:0];
          5'd14: resp_byte = st_bypass_cnt[15:8];
          5'd15: resp_byte = st_cycles[7:0];
          5'd16: resp_byte = st_cycles[15:8];
          5'd17: resp_byte = st_cycles[23:16];
          5'd18: resp_byte = st_cycles[31:24];
          5'd19: resp_byte = {1'b0, cfg_vec_len};
          5'd20: resp_byte = run_threshold;
          default: resp_byte = 8'h00;                      // 21..23 reserved
        endcase
      default: resp_byte = 8'h00;
    endcase
  end

  // set up an error response (also strobes the LED error pulse)
  task set_err;
    input [7:0] code;
    begin
      resp_cmd  <= 8'hFF;
      resp_len  <= 16'd1;
      resp_kind <= K_ERR;
      resp_err  <= code;
      err_code  <= code[3:0];
      err_pulse <= 1'b1;
      state     <= S_T_SOF;
    end
  endtask

  always @(posedge clk) begin
    if (rst) begin
      state <= S_IDLE;
      tx_data <= 8'd0; tx_valid <= 1'b0;
      ld_val_we <= 1'b0; ld_val_addr <= 15'd0; ld_val_data <= 8'd0;
      ld_imp_we <= 1'b0; ld_imp_addr <= 9'd0;  ld_imp_data <= 8'd0;
      run_start <= 1'b0;
      cfg_entry_count <= 10'd0; cfg_vec_len <= 7'd0; run_threshold <= 8'd0;
      rd_addr <= 16'd0;
      slice_loaded <= 1'b0; err_code <= 4'd0; err_pulse <= 1'b0;
      cmd <= 8'd0; len <= 16'd0; cksum_rx <= 8'd0; pay_cnt <= 16'd0;
      ld_count <= 16'd0; ld_vlen <= 8'd0; load_ok <= 1'b0;
      entry_i <= 10'd0; byte_j <= 7'd0;
      run_mode <= 8'd0; run_thr_pl <= 8'd0;
      is_btn <= 1'b0; had_run <= 1'b0;
      resp_cmd <= 8'd0; resp_len <= 16'd0; resp_kind <= K_ERR; resp_err <= 8'd0;
      cksum_tx <= 8'd0; pay_idx <= 16'd0;
      rs_start <= 1'b0;
      wd_cnt <= 32'd0;
    end else begin
      // 1-cycle strobe defaults
      ld_val_we <= 1'b0;
      ld_imp_we <= 1'b0;
      run_start <= 1'b0;
      err_pulse <= 1'b0;
      rs_start  <= 1'b0;

      // watchdog counts cycles without an RX byte while mid-frame
      if (in_rx_frame && !rx_valid)
        wd_cnt <= wd_cnt + 32'd1;
      else
        wd_cnt <= 32'd0;

      case (state)
        // ------------------------------------------------------- RX framing
        S_IDLE: begin
          if (rx_valid) begin
            if (rx_data == SOF_HOST)
              state <= S_CMD;
          end else if (btn_run && slice_loaded && !run_busy) begin
            // standalone run: RUN with mode=1 (switch threshold), no response
            run_threshold <= sw_threshold;
            is_btn <= 1'b1;
            state <= S_RUN_GO;
          end
        end

        S_CMD: if (rx_valid) begin
          cmd      <= rx_data;
          cksum_rx <= rx_data;
          load_ok  <= 1'b0;
          state    <= S_LEN_LO;
        end

        S_LEN_LO: if (rx_valid) begin
          len[7:0] <= rx_data;
          cksum_rx <= cksum_rx + rx_data;
          state    <= S_LEN_HI;
        end

        S_LEN_HI: if (rx_valid) begin
          len[15:8] <= rx_data;
          cksum_rx  <= cksum_rx + rx_data;
          pay_cnt   <= 16'd0;
          entry_i   <= 10'd0;
          byte_j    <= 7'd0;
          state     <= ({rx_data, len[7:0]} == 16'd0) ? S_CKSUM : S_PAY;
        end

        S_PAY: if (rx_valid) begin
          cksum_rx <= cksum_rx + rx_data;
          pay_cnt  <= pay_cnt + 16'd1;
          if (pay_cnt == len - 16'd1)
            state <= S_CKSUM;
          if (cmd == CMD_LOAD) begin
            case (pay_cnt)
              16'd0: ld_count[7:0]  <= rx_data;
              16'd1: ld_count[15:8] <= rx_data;
              16'd2: ld_vlen        <= rx_data;
              16'd3: load_ok        <= hdr_ok;   // rsvd byte: header complete, validate
              default: if (load_ok) begin
                // write-through: byte_j==0 -> importance, else value byte j = byte_j-1
                if (byte_j == 7'd0) begin
                  ld_imp_we   <= 1'b1;
                  ld_imp_addr <= entry_i[8:0];
                  ld_imp_data <= rx_data;
                  byte_j      <= 7'd1;
                end else begin
                  ld_val_we   <= 1'b1;
                  ld_val_addr <= {entry_i[8:0], jm1[5:0]};
                  ld_val_data <= rx_data;
                  if (byte_j == ld_vlen[6:0]) begin
                    byte_j  <= 7'd0;
                    entry_i <= entry_i + 10'd1;
                  end else
                    byte_j <= byte_j + 7'd1;
                end
              end
            endcase
          end else if (cmd == CMD_RUN) begin
            if (pay_cnt == 16'd0)
              run_mode <= rx_data;
            else if (pay_cnt == 16'd1)
              run_thr_pl <= rx_data;
          end
        end

        S_CKSUM: if (rx_valid) begin
          cksum_rx <= cksum_rx + rx_data;
          state    <= S_DISP;
        end

        // ------------------------------------------------------- dispatch
        S_DISP: begin
          if (cksum_rx != 8'd0) begin
            if (cmd == CMD_LOAD) begin
              // a partial/corrupt upload invalidates any previous slice
              slice_loaded <= 1'b0;
              had_run      <= 1'b0;
            end
            set_err(ERR_CKSUM);
          end else begin
            case (cmd)
              CMD_PING:
                if (len != 16'd0)
                  set_err(ERR_MALFORMED);
                else begin
                  resp_cmd  <= CMD_PING | 8'h80;
                  resp_len  <= 16'd4;
                  resp_kind <= K_PING;
                  state     <= S_T_SOF;
                end
              CMD_LOAD:
                if (!load_ok)
                  set_err(ERR_MALFORMED);
                else begin
                  cfg_entry_count <= ld_count[9:0];   // 512 -> 10'b1000000000
                  cfg_vec_len     <= ld_vlen[6:0];
                  slice_loaded    <= 1'b1;
                  had_run         <= 1'b0;
                  resp_cmd  <= CMD_LOAD | 8'h80;
                  resp_len  <= 16'd3;
                  resp_kind <= K_LOAD;
                  state     <= S_T_SOF;
                end
              CMD_RUN:
                if (len != 16'd2)
                  set_err(ERR_MALFORMED);
                else if (!slice_loaded)
                  set_err(ERR_NO_SLICE);
                else begin
                  run_threshold <= run_mode[0] ? sw_threshold : run_thr_pl;
                  is_btn        <= 1'b0;
                  state         <= S_RUN_GO;
                end
              CMD_STATS:
                if (len != 16'd0)
                  set_err(ERR_MALFORMED);
                else if (!had_run)
                  set_err(ERR_NO_SLICE);
                else begin
                  resp_cmd  <= CMD_STATS | 8'h80;
                  resp_len  <= 16'd24;
                  resp_kind <= K_STATS;
                  state     <= S_T_SOF;
                end
              CMD_DATA:
                if (len != 16'd0)
                  set_err(ERR_MALFORMED);
                else if (!had_run)
                  set_err(ERR_NO_SLICE);
                else begin
                  resp_cmd  <= CMD_DATA | 8'h80;
                  resp_len  <= st_comp_bytes[15:0];   // <= 33,344 by construction
                  resp_kind <= K_DATA;
                  state     <= S_T_SOF;
                end
              CMD_RSTR:
                if (len != 16'd0)
                  set_err(ERR_MALFORMED);
                else if (!had_run)
                  set_err(ERR_NO_SLICE);
                else begin
                  resp_cmd  <= CMD_RSTR | 8'h80;
                  resp_len  <= rs_len[15:0];          // <= 32,832 by construction
                  resp_kind <= K_RSTR;
                  rs_start  <= 1'b1;                  // restore_ctrl begins prefetching
                  state     <= S_T_SOF;
                end
              default: set_err(ERR_UNKNOWN);
            endcase
          end
        end

        // ------------------------------------------------------- run sequencing
        S_RUN_GO: if (!run_busy) begin
          run_start <= 1'b1;
          state     <= S_RUN_WT;
        end

        S_RUN_WT: if (run_done) begin
          had_run <= 1'b1;
          if (is_btn)
            state <= S_IDLE;         // standalone run: no response frame
          else begin
            resp_cmd  <= CMD_RUN | 8'h80;
            resp_len  <= 16'd24;
            resp_kind <= K_STATS;
            state     <= S_T_SOF;
          end
        end

        // ------------------------------------------------------- TX response
        // Per-byte pattern: load tx_data and raise tx_valid, hold until the
        // accept cycle (tx_valid && tx_ready), then drop valid and advance.
        S_T_SOF: begin
          if (!tx_valid) begin
            tx_data  <= SOF_DEV;
            tx_valid <= 1'b1;
            cksum_tx <= 8'd0;        // SOF excluded from checksum
          end else if (tx_ready) begin
            tx_valid <= 1'b0;
            state    <= S_T_CMD;
          end
        end

        S_T_CMD: begin
          if (!tx_valid) begin
            tx_data  <= resp_cmd;
            tx_valid <= 1'b1;
          end else if (tx_ready) begin
            tx_valid <= 1'b0;
            cksum_tx <= cksum_tx + tx_data;
            state    <= S_T_LENL;
          end
        end

        S_T_LENL: begin
          if (!tx_valid) begin
            tx_data  <= resp_len[7:0];
            tx_valid <= 1'b1;
          end else if (tx_ready) begin
            tx_valid <= 1'b0;
            cksum_tx <= cksum_tx + tx_data;
            state    <= S_T_LENH;
          end
        end

        S_T_LENH: begin
          if (!tx_valid) begin
            tx_data  <= resp_len[15:8];
            tx_valid <= 1'b1;
          end else if (tx_ready) begin
            tx_valid <= 1'b0;
            cksum_tx <= cksum_tx + tx_data;
            pay_idx  <= 16'd0;
            if (resp_len == 16'd0)
              state <= S_T_CKS;
            else if (resp_kind == K_DATA)
              state <= S_T_DADR;
            else if (resp_kind == K_RSTR)
              state <= S_T_RSND;
            else
              state <= S_T_PAY;
          end
        end

        S_T_PAY: begin
          if (!tx_valid) begin
            tx_data  <= resp_byte;
            tx_valid <= 1'b1;
          end else if (tx_ready) begin
            tx_valid <= 1'b0;
            cksum_tx <= cksum_tx + tx_data;
            if (pay_idx == resp_len - 16'd1)
              state <= S_T_CKS;
            else
              pay_idx <= pay_idx + 16'd1;
          end
        end

        // GET_DATA byte fetch: rd_addr held constant until the byte is
        // accepted, so rd_data stays stable across any tx_ready stall and the
        // byte is captured once into tx_data (no drop/duplicate).
        S_T_DADR: begin
          rd_addr <= pay_idx;
          state   <= S_T_DWT;
        end

        S_T_DWT: state <= S_T_DSND;  // out_mem output-register latency

        S_T_DSND: begin
          if (!tx_valid) begin
            tx_data  <= rd_data;
            tx_valid <= 1'b1;
          end else if (tx_ready) begin
            tx_valid <= 1'b0;
            cksum_tx <= cksum_tx + tx_data;
            if (pay_idx == resp_len - 16'd1)
              state <= S_T_CKS;
            else begin
              pay_idx <= pay_idx + 16'd1;
              state   <= S_T_DADR;
            end
          end
        end

        // GET_RESTORED byte: latched from the restore stream the same cycle
        // rs_ready consumes it (see assign above), then paced by tx_ready.
        S_T_RSND: begin
          if (!tx_valid) begin
            if (rs_valid) begin
              tx_data  <= rs_data;
              tx_valid <= 1'b1;
            end
          end else if (tx_ready) begin
            tx_valid <= 1'b0;
            cksum_tx <= cksum_tx + tx_data;
            if (pay_idx == resp_len - 16'd1)
              state <= S_T_CKS;
            else
              pay_idx <= pay_idx + 16'd1;
          end
        end

        S_T_CKS: begin
          if (!tx_valid) begin
            tx_data  <= 8'd0 - cksum_tx;   // two's complement of running sum
            tx_valid <= 1'b1;
          end else if (tx_ready) begin
            tx_valid <= 1'b0;
            state    <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase

      // watchdog expiry mid-frame: silently drop to idle, no response.
      // If write-through of a LOAD payload had already begun, the slice
      // memory is partially overwritten -> invalidate any previous slice.
      if (in_rx_frame && !rx_valid && (wd_cnt >= WATCHDOG_CYCLES - 1)) begin
        state <= S_IDLE;
        if ((state == S_PAY || state == S_CKSUM) && cmd == CMD_LOAD && load_ok) begin
          slice_loaded <= 1'b0;
          had_run      <= 1'b0;
        end
      end
    end
  end

endmodule
