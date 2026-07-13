// stats_regs: run statistics counters. 'clr' (strobed at run_start) zeroes everything.
// orig_bytes accumulates vec_len on each entry_inc strobe (no multiplier).
// cycles increments every cycle cyc_en is high (cyc_en == run_busy).
module stats_regs (
  input  wire        clk, rst,
  input  wire        clr,            // strobe at run_start: zero all counters
  input  wire        cyc_en,         // count cycles while high (== run_busy)
  input  wire        entry_inc,      // strobe per entry examined (adds vec_len to orig_bytes)
  input  wire        kept_inc, bypass_inc,
  input  wire [6:0]  vec_len,
  input  wire        comp_set, input wire [31:0] comp_bytes_in,  // final wptr at done
  output reg  [15:0] entries_in, entries_kept, bypass_cnt,
  output reg  [31:0] orig_bytes, comp_bytes, cycles
);

  always @(posedge clk) begin
    if (rst || clr) begin
      entries_in   <= 16'd0;
      entries_kept <= 16'd0;
      bypass_cnt   <= 16'd0;
      orig_bytes   <= 32'd0;
      comp_bytes   <= 32'd0;
      cycles       <= 32'd0;
    end else begin
      if (entry_inc) begin
        entries_in <= entries_in + 16'd1;
        orig_bytes <= orig_bytes + {25'd0, vec_len};
      end
      if (kept_inc)   entries_kept <= entries_kept + 16'd1;
      if (bypass_inc) bypass_cnt   <= bypass_cnt + 16'd1;
      if (cyc_en)     cycles       <= cycles + 32'd1;
      if (comp_set)   comp_bytes   <= comp_bytes_in;
    end
  end

endmodule
