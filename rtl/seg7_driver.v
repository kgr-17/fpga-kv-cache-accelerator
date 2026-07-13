// seg7_driver: 16-bit binary value -> 4 decimal digits on the Basys 3 7-segment display.
// Combinational double-dabble (value only changes on run boundaries, so the long
// combinational chain is registered once and is not timing-critical).
// Saturates display at 9999. Segments and anodes are active-low.
// o_seg = {CG,CF,CE,CD,CC,CB,CA}; digit period 2^17 cycles (~763 Hz scan per digit).
module seg7_driver (
  input  wire        clk, rst,
  input  wire [15:0] i_value,
  output reg  [6:0]  o_seg,
  output reg  [3:0]  o_an
);

  // Saturate before conversion: 9999 fits in 14 bits.
  wire [13:0] sat = (i_value > 16'd9999) ? 14'd9999 : i_value[13:0];

  // Double-dabble: 14-bit binary -> 4 BCD digits.
  function [15:0] bin2bcd;
    input [13:0] bin;
    integer k;
    reg [29:0] sh;   // {BCD[15:0], bin[13:0]}
    begin
      sh = {16'd0, bin};
      for (k = 0; k < 14; k = k + 1) begin
        if (sh[17:14] >= 4'd5) sh[17:14] = sh[17:14] + 4'd3;
        if (sh[21:18] >= 4'd5) sh[21:18] = sh[21:18] + 4'd3;
        if (sh[25:22] >= 4'd5) sh[25:22] = sh[25:22] + 4'd3;
        if (sh[29:26] >= 4'd5) sh[29:26] = sh[29:26] + 4'd3;
        sh = sh << 1;
      end
      bin2bcd = sh[29:14];
    end
  endfunction

  // Active-low segment patterns, {CG,CF,CE,CD,CC,CB,CA}.
  function [6:0] seg_dec;
    input [3:0] d;
    begin
      case (d)
        4'd0:    seg_dec = 7'b1000000;
        4'd1:    seg_dec = 7'b1111001;
        4'd2:    seg_dec = 7'b0100100;
        4'd3:    seg_dec = 7'b0110000;
        4'd4:    seg_dec = 7'b0011001;
        4'd5:    seg_dec = 7'b0010010;
        4'd6:    seg_dec = 7'b0000010;
        4'd7:    seg_dec = 7'b1111000;
        4'd8:    seg_dec = 7'b0000000;
        4'd9:    seg_dec = 7'b0010000;
        default: seg_dec = 7'b1111111;  // blank (unreachable: BCD digits only)
      endcase
    end
  endfunction

  reg [15:0] bcd;
  reg [18:0] scan_cnt;                       // [18:17] selects the active digit
  wire [1:0] digit_sel = scan_cnt[18:17];

  always @(posedge clk) begin
    if (rst) begin
      bcd      <= 16'd0;
      scan_cnt <= 19'd0;
      o_seg    <= 7'b1111111;
      o_an     <= 4'b1111;
    end else begin
      bcd      <= bin2bcd(sat);
      scan_cnt <= scan_cnt + 19'd1;
      case (digit_sel)
        2'd0: begin o_an <= 4'b1110; o_seg <= seg_dec(bcd[3:0]);   end
        2'd1: begin o_an <= 4'b1101; o_seg <= seg_dec(bcd[7:4]);   end
        2'd2: begin o_an <= 4'b1011; o_seg <= seg_dec(bcd[11:8]);  end
        2'd3: begin o_an <= 4'b0111; o_seg <= seg_dec(bcd[15:12]); end
      endcase
    end
  end

endmodule
