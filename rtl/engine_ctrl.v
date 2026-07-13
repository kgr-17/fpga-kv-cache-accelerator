// engine_ctrl.v -- KV-cache compression engine sequencer (see docs/interfaces.md,
// docs/encoding.md). For each entry: read importance (sync BRAM, 1-cycle latency),
// evict or stream the vector through the external delta->rle->vec_buffer chain,
// then write HDR + payload (RLE copy or raw bypass re-read) to out_mem. Bitmap is
// kept in 512 FFs and written to out_mem[0..bm_len-1] after the last entry.
module engine_ctrl (
  input  wire        clk,
  input  wire        rst,
  input  wire        i_start,                      // run_start
  input  wire [9:0]  i_entry_count,
  input  wire [6:0]  i_vec_len,
  input  wire [7:0]  i_thresh,
  output reg         o_busy,
  output reg         o_done,                       // 1-cycle strobe
  // slice_mem port B + importance read
  output reg  [14:0] val_addr,
  input  wire [7:0]  val_data,
  output reg  [8:0]  imp_addr,
  input  wire [7:0]  imp_data,
  // pipeline: engine drives delta_enc input
  output reg  [7:0]  pipe_data,
  output reg         pipe_valid,
  output reg         pipe_sov,
  output reg         pipe_eov,
  input  wire        pipe_ready,                   // from delta_enc
  input  wire [7:0]  vb_clen,
  input  wire        vb_done,
  output reg         vb_clr,
  output reg  [6:0]  vb_rd_addr,
  input  wire [7:0]  vb_rd_data,
  // out_mem write
  output reg         om_we,
  output reg  [15:0] om_addr,
  output reg  [7:0]  om_din,
  // stats strobes
  output reg         st_entry_inc,
  output reg         st_kept_inc,
  output reg         st_bypass_inc,
  output reg         st_comp_set,
  output reg  [31:0] st_comp_bytes
);

  localparam S_IDLE  = 4'd0;   // wait for i_start
  localparam S_IMPRD = 4'd1;   // imp_addr stable on BRAM input this cycle
  localparam S_EVAL  = 4'd2;   // imp_data valid this cycle: evict/keep decision
  localparam S_VADDR = 4'd3;   // val_addr stable on BRAM input this cycle
  localparam S_VCAP  = 4'd4;   // val_data valid this cycle: capture into pipe regs
  localparam S_VSEND = 4'd5;   // pipe_valid held high until pipe_ready
  localparam S_WVB   = 4'd6;   // wait for vec_buffer done, decide HDR/bypass
  localparam S_CPY   = 4'd7;   // copy vec_buffer[0..clen-1] (async read) to out_mem
  localparam S_RAWA  = 4'd8;   // bypass: val_addr stable this cycle
  localparam S_RAWW  = 4'd9;   // bypass: val_data valid this cycle, write to out_mem
  localparam S_BM    = 4'd10;  // write bitmap bytes to out_mem[0..bm_len-1]
  localparam S_FIN   = 4'd11;  // pulse st_comp_set with final wptr
  localparam S_DONE  = 4'd12;  // pulse o_done

  reg [3:0]   state;
  reg [9:0]   cnt_r;      // latched entry count (1..512)
  reg [6:0]   len_r;      // latched vec_len (1..64)
  reg [7:0]   thr_r;      // latched threshold
  reg [6:0]   bm_len_r;   // bitmap byte count = (entry_count+7)>>3
  reg [9:0]   idx;        // current entry index
  reg [6:0]   j;          // byte index within vector (stream / raw copy)
  reg [7:0]   kk;         // vec_buffer copy index (clen <= 96)
  reg [7:0]   clen_r;     // latched RLE length of current vector
  reg [15:0]  wptr;       // out_mem write pointer (starts at bm_len)
  reg [6:0]   b;          // bitmap byte index during S_BM
  reg [511:0] bm;         // keep bitmap: entry i -> bit i (LSB-first packing)

  wire keep_w;
  evict_filter u_filt (
    .i_imp    (imp_data),
    .i_thresh (thr_r),
    .o_keep   (keep_w)
  );

  wire [9:0] idx_n   = idx + 10'd1;
  wire [6:0] j_n     = j + 7'd1;
  wire [7:0] kk_n    = kk + 8'd1;
  wire [9:0] bmlen_w = (i_entry_count + 10'd7) >> 3;

  always @(posedge clk) begin
    if (rst) begin
      state         <= S_IDLE;
      o_busy        <= 1'b0;
      o_done        <= 1'b0;
      val_addr      <= 15'd0;
      imp_addr      <= 9'd0;
      pipe_data     <= 8'd0;
      pipe_valid    <= 1'b0;
      pipe_sov      <= 1'b0;
      pipe_eov      <= 1'b0;
      vb_clr        <= 1'b0;
      vb_rd_addr    <= 7'd0;
      om_we         <= 1'b0;
      om_addr       <= 16'd0;
      om_din        <= 8'd0;
      st_entry_inc  <= 1'b0;
      st_kept_inc   <= 1'b0;
      st_bypass_inc <= 1'b0;
      st_comp_set   <= 1'b0;
      st_comp_bytes <= 32'd0;
      cnt_r         <= 10'd0;
      len_r         <= 7'd0;
      thr_r         <= 8'd0;
      bm_len_r      <= 7'd0;
      idx           <= 10'd0;
      j             <= 7'd0;
      kk            <= 8'd0;
      clen_r        <= 8'd0;
      wptr          <= 16'd0;
      b             <= 7'd0;
      bm            <= 512'd0;
    end else begin
      // default: all strobes are 1-cycle
      o_done        <= 1'b0;
      vb_clr        <= 1'b0;
      om_we         <= 1'b0;
      st_entry_inc  <= 1'b0;
      st_kept_inc   <= 1'b0;
      st_bypass_inc <= 1'b0;
      st_comp_set   <= 1'b0;

      case (state)

        S_IDLE: begin
          // o_busy stays high through the o_done pulse cycle, then drops here
          o_busy <= 1'b0;
          if (i_start) begin
            o_busy   <= 1'b1;
            cnt_r    <= i_entry_count;
            len_r    <= i_vec_len;
            thr_r    <= i_thresh;
            bm_len_r <= bmlen_w[6:0];
            wptr     <= {9'd0, bmlen_w[6:0]};   // entry data region starts after bitmap
            idx      <= 10'd0;
            imp_addr <= 9'd0;
            bm       <= 512'd0;
            state    <= S_IMPRD;
          end
        end

        S_IMPRD: begin
          // imp_addr is on the BRAM input this cycle; imp_data valid next cycle
          state <= S_EVAL;
        end

        S_EVAL: begin
          st_entry_inc <= 1'b1;
          bm[idx[8:0]] <= keep_w;
          if (keep_w) begin
            st_kept_inc <= 1'b1;
            vb_clr      <= 1'b1;
            j           <= 7'd0;
            val_addr    <= {idx[8:0], 6'd0};
            state       <= S_VADDR;
          end else begin
            // evicted: advance to next entry (or bitmap phase)
            if (idx_n == cnt_r) begin
              b     <= 7'd0;
              state <= S_BM;
            end else begin
              idx      <= idx_n;
              imp_addr <= idx_n[8:0];
              state    <= S_IMPRD;
            end
          end
        end

        S_VADDR: begin
          state <= S_VCAP;
        end

        S_VCAP: begin
          // val_data valid this cycle: present it on the pipe next cycle
          pipe_data  <= val_data;
          pipe_valid <= 1'b1;
          pipe_sov   <= (j == 7'd0);
          pipe_eov   <= (j_n == len_r);
          state      <= S_VSEND;
        end

        S_VSEND: begin
          if (pipe_ready) begin
            pipe_valid <= 1'b0;
            pipe_sov   <= 1'b0;
            pipe_eov   <= 1'b0;
            if (j_n == len_r) begin
              state <= S_WVB;
            end else begin
              j        <= j_n;
              val_addr <= {idx[8:0], j_n[5:0]};
              state    <= S_VADDR;
            end
          end
        end

        S_WVB: begin
          if (vb_done) begin
            if (vb_clen < {1'b0, len_r}) begin
              // compressed: HDR = clen (bypass bit clear), then clen RLE bytes
              om_we   <= 1'b1;
              om_addr <= wptr;
              om_din  <= vb_clen;
              wptr    <= wptr + 16'd1;
              clen_r  <= vb_clen;
              kk      <= 8'd0;
              vb_rd_addr <= 7'd0;
              if (vb_clen == 8'd0) begin
                // cannot occur per encoding spec (clen >= 1); defensive guard
                if (idx_n == cnt_r) begin
                  b     <= 7'd0;
                  state <= S_BM;
                end else begin
                  idx      <= idx_n;
                  imp_addr <= idx_n[8:0];
                  state    <= S_IMPRD;
                end
              end else begin
                state <= S_CPY;
              end
            end else begin
              // bypass: HDR = 0x80 | vec_len, then vec_len raw bytes re-read
              st_bypass_inc <= 1'b1;
              om_we    <= 1'b1;
              om_addr  <= wptr;
              om_din   <= {1'b1, len_r};
              wptr     <= wptr + 16'd1;
              j        <= 7'd0;
              val_addr <= {idx[8:0], 6'd0};
              state    <= S_RAWA;
            end
          end
        end

        S_CPY: begin
          // vec_buffer read is async LUTRAM: vb_rd_data valid this cycle
          om_we   <= 1'b1;
          om_addr <= wptr;
          om_din  <= vb_rd_data;
          wptr    <= wptr + 16'd1;
          if (kk_n == clen_r) begin
            if (idx_n == cnt_r) begin
              b     <= 7'd0;
              state <= S_BM;
            end else begin
              idx      <= idx_n;
              imp_addr <= idx_n[8:0];
              state    <= S_IMPRD;
            end
          end else begin
            kk         <= kk_n;
            vb_rd_addr <= kk_n[6:0];
          end
        end

        S_RAWA: begin
          state <= S_RAWW;
        end

        S_RAWW: begin
          om_we   <= 1'b1;
          om_addr <= wptr;
          om_din  <= val_data;
          wptr    <= wptr + 16'd1;
          if (j_n == len_r) begin
            if (idx_n == cnt_r) begin
              b     <= 7'd0;
              state <= S_BM;
            end else begin
              idx      <= idx_n;
              imp_addr <= idx_n[8:0];
              state    <= S_IMPRD;
            end
          end else begin
            j        <= j_n;
            val_addr <= {idx[8:0], j_n[5:0]};
            state    <= S_RAWA;
          end
        end

        S_BM: begin
          om_we   <= 1'b1;
          om_addr <= {9'd0, b};
          om_din  <= bm[{b, 3'b000} +: 8];
          if (b == bm_len_r - 7'd1) begin
            state <= S_FIN;
          end else begin
            b <= b + 7'd1;
          end
        end

        S_FIN: begin
          st_comp_set   <= 1'b1;
          st_comp_bytes <= {16'd0, wptr};   // final wptr = total stream length
          state         <= S_DONE;
        end

        S_DONE: begin
          o_done <= 1'b1;
          state  <= S_IDLE;
        end

        default: begin
          state <= S_IDLE;
        end
      endcase
    end
  end

endmodule
