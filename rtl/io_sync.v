// io_sync: 2-FF synchronizer for the 16 switches; btnU gets 2-FF sync, ~1 ms debounce
// (level must be stable for 100,000 cycles at 100 MHz before it is accepted), then a
// rising-edge detector producing a 1-cycle pulse.
module io_sync (
  input  wire        clk, rst,
  input  wire [15:0] i_sw,  output wire [15:0] o_sw,     // 2-FF sync
  input  wire        i_btnu, output wire o_btnu_pulse    // sync + ~1ms debounce + edge pulse
);

  localparam DB_MAX = 17'd99_999;   // 100,000 cycles = 1 ms at 100 MHz

  reg [15:0] sw_ff1, sw_ff2;
  reg        btn_ff1, btn_ff2;
  reg        btn_db;                // debounced level
  reg        btn_db_d;              // delayed for rising-edge detect
  reg [16:0] db_cnt;

  always @(posedge clk) begin
    if (rst) begin
      sw_ff1   <= 16'd0;
      sw_ff2   <= 16'd0;
      btn_ff1  <= 1'b0;
      btn_ff2  <= 1'b0;
      btn_db   <= 1'b0;
      btn_db_d <= 1'b0;
      db_cnt   <= 17'd0;
    end else begin
      sw_ff1  <= i_sw;
      sw_ff2  <= sw_ff1;
      btn_ff1 <= i_btnu;
      btn_ff2 <= btn_ff1;
      if (btn_ff2 == btn_db) begin
        db_cnt <= 17'd0;            // stable at current level: nothing to debounce
      end else if (db_cnt == DB_MAX) begin
        btn_db <= btn_ff2;          // new level held for ~1 ms: accept it
        db_cnt <= 17'd0;
      end else begin
        db_cnt <= db_cnt + 17'd1;
      end
      btn_db_d <= btn_db;
    end
  end

  assign o_sw         = sw_ff2;
  assign o_btnu_pulse = btn_db & ~btn_db_d;

endmodule
