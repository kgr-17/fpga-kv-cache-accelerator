// evict_filter: eviction compare per docs/interfaces.md and docs/encoding.md.
// Entry is kept iff importance >= threshold (unsigned 8-bit compare).
module evict_filter (
  input  wire [7:0] i_imp,
  input  wire [7:0] i_thresh,
  output wire       o_keep
);

  assign o_keep = (i_imp >= i_thresh);

endmodule
