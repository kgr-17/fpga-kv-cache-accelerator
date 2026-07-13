// restore_ctrl: v1.1 hardware decompressor sequencer (docs/interfaces.md).
// Walks the compressed stream in out_mem and produces the GET_RESTORED
// payload: bitmap bytes verbatim (latched to know the kept set), then per
// kept entry the restored vec_len original bytes — bypass payloads copied
// raw, compressed payloads routed through rle_dec -> delta_dec.
// Produces exactly bm_len + entries_kept*vec_len bytes, then pulses o_done.
//
// out_mem read discipline (sync BRAM, output register): set om_addr in one
// state, wait one state, use om_data in the second state after. ~4 cycles
// per byte — irrelevant next to the UART draining the stream.
module restore_ctrl (
  input  wire        clk,
  input  wire        rst,
  input  wire        i_start,
  input  wire [9:0]  i_entry_count,
  input  wire [6:0]  i_vec_len,
  output reg         o_active,
  output reg  [15:0] om_addr,
  input  wire [7:0]  om_data,
  output wire [7:0]  o_data,
  output wire        o_valid,
  input  wire        o_ready,
  output reg         o_done
);

  localparam [3:0] P_IDLE    = 4'd0,
                   P_BM_A    = 4'd1,  P_BM_W   = 4'd2,
                   P_BM_CAP  = 4'd3,  P_BM_HLD = 4'd4,
                   P_NEXT    = 4'd5,
                   P_HDR_A   = 4'd6,  P_HDR_W  = 4'd7,  P_HDR_D = 4'd8,
                   P_RAW_A   = 4'd9,  P_RAW_W  = 4'd10,
                   P_RAW_CAP = 4'd11, P_RAW_HLD = 4'd12,
                   P_CMP     = 4'd13,
                   P_FIN     = 4'd14;

  // feeder sub-state inside P_CMP
  localparam [2:0] F_A = 3'd0, F_W = 3'd1, F_CAP = 3'd2, F_HLD = 3'd3,
                   F_IDLE = 3'd4;

  reg [3:0]   phase;
  reg [2:0]   fs;
  reg [511:0] bitmap;
  reg [6:0]   bm_len, bm_idx;
  reg [9:0]   entry;
  reg [15:0]  rd_ptr;              // next compressed-stream byte to fetch
  reg         byp;
  reg [6:0]   plen;                // payload bytes for this entry (clen or vec_len)
  reg [6:0]   fed_cnt;             // payload bytes fed to rle_dec
  reg [6:0]   out_cnt;             // restored bytes accepted at module output

  // presenter for bitmap/raw bytes (register-and-hold until accepted)
  reg  [7:0]  pres_data;
  reg         pres_valid;

  // rle_dec input presenter
  reg  [7:0]  rle_in_data;
  reg         rle_in_valid;
  reg         rle_clr;

  wire        cmp_active = (phase == P_CMP);

  // ---------------------------------------------------------------- decoders
  wire        rle_in_ready;
  wire [7:0]  rd_data;
  wire        rd_valid;
  wire        dd_ready;

  rle_dec u_rle_dec (
    .clk(clk), .rst(rst), .i_clr(rle_clr),
    .i_data(rle_in_data), .i_valid(rle_in_valid), .i_ready(rle_in_ready),
    .o_data(rd_data), .o_valid(rd_valid), .o_ready(dd_ready)
  );

  wire [7:0] dd_data;
  wire       dd_valid;

  delta_dec u_delta_dec (
    .clk(clk), .rst(rst),
    .i_data(rd_data), .i_valid(rd_valid), .i_sov(out_cnt == 7'd0),
    .i_ready(dd_ready),
    .o_data(dd_data), .o_valid(dd_valid),
    .o_ready(cmp_active ? o_ready : 1'b0)
  );

  assign o_data  = cmp_active ? dd_data  : pres_data;
  assign o_valid = cmp_active ? dd_valid : pres_valid;

  wire out_accept = o_valid && o_ready;

  always @(posedge clk) begin
    if (rst) begin
      phase <= P_IDLE; fs <= F_IDLE;
      bitmap <= 512'd0; bm_len <= 7'd0; bm_idx <= 7'd0;
      entry <= 10'd0; rd_ptr <= 16'd0;
      byp <= 1'b0; plen <= 7'd0; fed_cnt <= 7'd0; out_cnt <= 7'd0;
      pres_data <= 8'd0; pres_valid <= 1'b0;
      rle_in_data <= 8'd0; rle_in_valid <= 1'b0; rle_clr <= 1'b0;
      om_addr <= 16'd0; o_active <= 1'b0; o_done <= 1'b0;
    end else begin
      o_done  <= 1'b0;
      rle_clr <= 1'b0;

      case (phase)
        P_IDLE: if (i_start) begin
          o_active <= 1'b1;
          bm_len   <= (i_entry_count + 10'd7) >> 3;
          bm_idx   <= 7'd0;
          phase    <= P_BM_A;
        end

        // ------------------------------------------------ bitmap streaming
        P_BM_A: begin
          om_addr <= {9'd0, bm_idx};
          phase   <= P_BM_W;
        end
        P_BM_W: phase <= P_BM_CAP;
        P_BM_CAP: begin
          bitmap[{bm_idx[5:0], 3'b000} +: 8] <= om_data;
          pres_data  <= om_data;
          pres_valid <= 1'b1;
          phase      <= P_BM_HLD;
        end
        P_BM_HLD: if (out_accept) begin
          pres_valid <= 1'b0;
          if (bm_idx == bm_len - 7'd1) begin
            entry  <= 10'd0;
            rd_ptr <= {9'd0, bm_len};
            phase  <= P_NEXT;
          end else begin
            bm_idx <= bm_idx + 7'd1;
            phase  <= P_BM_A;
          end
        end

        // ------------------------------------------------ entry loop
        P_NEXT: begin
          if (entry == i_entry_count)
            phase <= P_FIN;
          else if (bitmap[entry[8:0]])
            phase <= P_HDR_A;
          else
            entry <= entry + 10'd1;
        end

        P_HDR_A: begin
          om_addr <= rd_ptr;
          phase   <= P_HDR_W;
        end
        P_HDR_W: phase <= P_HDR_D;
        P_HDR_D: begin
          byp     <= om_data[7];
          plen    <= om_data[7] ? i_vec_len : om_data[6:0];
          rd_ptr  <= rd_ptr + 16'd1;
          fed_cnt <= 7'd0;
          out_cnt <= 7'd0;
          if (om_data[7])
            phase <= P_RAW_A;
          else begin
            rle_clr <= 1'b1;
            fs      <= F_A;
            phase   <= P_CMP;
          end
        end

        // ------------------------------------------------ bypass: raw copy
        P_RAW_A: begin
          om_addr <= rd_ptr;
          phase   <= P_RAW_W;
        end
        P_RAW_W: phase <= P_RAW_CAP;
        P_RAW_CAP: begin
          pres_data  <= om_data;
          pres_valid <= 1'b1;
          phase      <= P_RAW_HLD;
        end
        P_RAW_HLD: if (out_accept) begin
          pres_valid <= 1'b0;
          rd_ptr     <= rd_ptr + 16'd1;
          if (out_cnt == i_vec_len - 7'd1) begin
            entry <= entry + 10'd1;
            phase <= P_NEXT;
          end else begin
            out_cnt <= out_cnt + 7'd1;
            phase   <= P_RAW_A;
          end
        end

        // ------------------------------------------------ compressed entry
        // Feeder (fs) pushes payload bytes into rle_dec while the decoder
        // chain drains through the module output at o_ready's pace.
        P_CMP: begin
          case (fs)
            F_A: begin
              if (fed_cnt == plen)
                fs <= F_IDLE;
              else begin
                om_addr <= rd_ptr;
                fs      <= F_W;
              end
            end
            F_W: fs <= F_CAP;
            F_CAP: begin
              rle_in_data  <= om_data;
              rle_in_valid <= 1'b1;
              fs           <= F_HLD;
            end
            F_HLD: if (rle_in_ready) begin
              rle_in_valid <= 1'b0;
              rd_ptr       <= rd_ptr + 16'd1;
              fed_cnt      <= fed_cnt + 7'd1;
              fs           <= F_A;
            end
            default: ;                       // F_IDLE: feeding finished
          endcase
          if (out_accept) begin
            if (out_cnt == i_vec_len - 7'd1) begin
              entry <= entry + 10'd1;
              phase <= P_NEXT;
            end else
              out_cnt <= out_cnt + 7'd1;
          end
        end

        P_FIN: begin
          o_active <= 1'b0;
          o_done   <= 1'b1;
          phase    <= P_IDLE;
        end

        default: phase <= P_IDLE;
      endcase
    end
  end

endmodule
