`timescale 1ns/1ps
// tb_kv_top_full.v — full-system UART transaction test for kv_top.
//
// Phase 1: replay uart_in.hex byte-by-byte over RsRx and collect every RsTx
// response byte; compare against uart_expected.hex under uart_mask.hex
// (mask 00 = skip byte, otherwise must match). The stimulus ends with a
// deliberately truncated frame, so after phase 1 the TB idles for
// 3*WATCHDOG_CYCLES to let the protocol watchdog recover, then phase 2
// replays uart_in2.hex and checks uart_expected2.hex (all bytes compared).

module tb_kv_top_full;

  parameter VEC_DIR = "../../../../sim/vectors";

  localparam CLKS_PER_BIT    = 20;
  localparam WATCHDOG_CYCLES = 4000;
  localparam MAXB            = 4096;

  reg         clk;
  reg         btnC, btnU;
  reg  [15:0] sw;
  reg         RsRx;
  wire [15:0] led;
  wire [6:0]  seg;
  wire [3:0]  an;
  wire        RsTx;

  kv_top #(
    .CLKS_PER_BIT   (CLKS_PER_BIT),
    .WATCHDOG_CYCLES(WATCHDOG_CYCLES)
  ) dut (
    .clk  (clk),
    .btnC (btnC),
    .btnU (btnU),
    .sw   (sw),
    .led  (led),
    .seg  (seg),
    .an   (an),
    .RsRx (RsRx),
    .RsTx (RsTx)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // global timeout watchdog
  initial begin
    #200_000_000;
    $display("FAIL: tb_kv_top_full global timeout");
    $finish;
  end

  // ---------------------------------------------------------------- vectors
  reg [7:0] in1  [0:MAXB-1];
  reg [7:0] exp1 [0:MAXB-1];
  reg [7:0] msk1 [0:MAXB-1];
  reg [7:0] in2  [0:MAXB-1];
  reg [7:0] exp2 [0:MAXB-1];
  reg [7:0] msk2 [0:MAXB-1];
  integer n_in1, n_exp1, n_in2, n_exp2;

  // ------------------------------------------------------------ RsTx monitor
  // Detect the start-bit falling edge, sample every bit mid-cell
  // (CLKS_PER_BIT/2 clocks in), collect bytes into rx_bytes[].
  reg [7:0] rx_bytes [0:MAXB-1];
  integer   rx_count;
  reg [7:0] mon_byte;
  integer   mk;

  initial rx_count = 0;

  always begin
    @(negedge RsTx);
    repeat (CLKS_PER_BIT/2) @(posedge clk);      // middle of start bit
    if (RsTx === 1'b0) begin                     // confirmed start (not a glitch)
      for (mk = 0; mk < 8; mk = mk + 1) begin
        repeat (CLKS_PER_BIT) @(posedge clk);    // middle of data bit, LSB first
        mon_byte[mk] = RsTx;
      end
      repeat (CLKS_PER_BIT) @(posedge clk);      // middle of stop bit
      if (RsTx !== 1'b1) begin
        $display("FAIL: tb_kv_top_full stop-bit error at rx byte %0d", rx_count);
        $finish;
      end
      rx_bytes[rx_count] = mon_byte;
      rx_count = rx_count + 1;
    end
  end

  // ------------------------------------------------------------ UART driver
  // 8N1, LSB first, each bit CLKS_PER_BIT clocks, ~2 idle bit-times per byte.
  task uart_send_byte;
    input [7:0] b;
    integer k;
    begin
      RsRx <= 1'b0;                              // start bit
      repeat (CLKS_PER_BIT) @(posedge clk);
      for (k = 0; k < 8; k = k + 1) begin
        RsRx <= b[k];
        repeat (CLKS_PER_BIT) @(posedge clk);
      end
      RsRx <= 1'b1;                              // stop bit
      repeat (CLKS_PER_BIT) @(posedge clk);
      repeat (2*CLKS_PER_BIT) @(posedge clk);    // inter-byte idle
    end
  endtask

  task wait_for_rx;
    input integer target;
    integer guard;
    begin
      guard = 0;
      while ((rx_count < target) && (guard < 5_000_000)) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (rx_count < target) begin
        $display("FAIL: tb_kv_top_full timeout waiting for %0d response bytes (got %0d)",
                 target, rx_count);
        $finish;
      end
    end
  endtask

  // ------------------------------------------------------------------- main
  integer i;
  integer ip, ep, flen, rlen;

  initial begin
    btnC = 1'b0;
    btnU = 1'b0;
    sw   = 16'h0000;
    RsRx = 1'b1;                                 // UART idles high

    // preset to x so file lengths can be recovered after $readmemh
    for (i = 0; i < MAXB; i = i + 1) begin
      in1[i]  = 8'hxx;
      exp1[i] = 8'hxx;
      msk1[i] = 8'hxx;
      in2[i]  = 8'hxx;
      exp2[i] = 8'hxx;
      msk2[i] = 8'hxx;
    end
    $readmemh({VEC_DIR, "/uart_in.hex"},        in1);
    $readmemh({VEC_DIR, "/uart_expected.hex"},  exp1);
    $readmemh({VEC_DIR, "/uart_mask.hex"},      msk1);
    $readmemh({VEC_DIR, "/uart_in2.hex"},       in2);
    $readmemh({VEC_DIR, "/uart_expected2.hex"}, exp2);
    $readmemh({VEC_DIR, "/uart_mask2.hex"},     msk2);

    // length = index of the first entry still x (scan down, keep lowest)
    n_in1 = MAXB; n_exp1 = MAXB; n_in2 = MAXB; n_exp2 = MAXB;
    for (i = MAXB-1; i >= 0; i = i - 1) begin
      if (^in1[i]  === 1'bx) n_in1  = i;
      if (^exp1[i] === 1'bx) n_exp1 = i;
      if (^in2[i]  === 1'bx) n_in2  = i;
      if (^exp2[i] === 1'bx) n_exp2 = i;
    end
    if ((n_in1 == 0) || (n_exp1 == 0) || (n_in2 == 0) || (n_exp2 == 0)) begin
      $display("FAIL: tb_kv_top_full vector files missing or empty");
      $finish;
    end

    repeat (50) @(posedge clk);                  // let the internal POR expire

    // -------------------------------------------------------------- phase 1
    // The protocol is command-response lockstep (docs/protocol.md): send one
    // complete frame, wait for its full response, then send the next. Frame
    // boundaries come from each frame's own LEN field. A frame whose declared
    // length exceeds the remaining stimulus is the deliberately truncated
    // final frame: send what exists and expect no response (watchdog cleans up).
    ip = 0;
    ep = 0;
    while (ip < n_in1) begin
      if (ip + 4 <= n_in1)
        flen = 5 + in1[ip+2] + (in1[ip+3] << 8);
      else
        flen = n_in1 - ip + 1;                   // even the header is truncated
      if (ip + flen <= n_in1) begin
        for (i = 0; i < flen; i = i + 1)
          uart_send_byte(in1[ip+i]);
        rlen = 5 + exp1[ep+2] + (exp1[ep+3] << 8);
        wait_for_rx(ep + rlen);
        ep = ep + rlen;
        ip = ip + flen;
      end else begin
        for (i = ip; i < n_in1; i = i + 1)
          uart_send_byte(in1[i]);
        ip = n_in1;
      end
    end
    if (ep != n_exp1) begin
      $display("FAIL: tb_kv_top_full phase1 response accounting %0d != %0d",
               ep, n_exp1);
      $finish;
    end
    for (i = 0; i < n_exp1; i = i + 1) begin
      if ((msk1[i] !== 8'h00) && (rx_bytes[i] !== exp1[i])) begin
        $display("FAIL: tb_kv_top_full phase1 idx %0d got %h expected %h",
                 i, rx_bytes[i], exp1[i]);
        $finish;
      end
    end

    // watchdog recovery from the deliberately truncated final frame
    repeat (3*WATCHDOG_CYCLES) @(posedge clk);

    // -------------------------------------------------------------- phase 2
    for (i = 0; i < n_in2; i = i + 1)
      uart_send_byte(in2[i]);
    wait_for_rx(n_exp1 + n_exp2);
    for (i = 0; i < n_exp2; i = i + 1) begin
      if ((msk2[i] !== 8'h00) && (rx_bytes[n_exp1 + i] !== exp2[i])) begin
        $display("FAIL: tb_kv_top_full phase2 idx %0d got %h expected %h",
                 i, rx_bytes[n_exp1 + i], exp2[i]);
        $finish;
      end
    end

    $display("PASS: tb_kv_top_full");
    $finish;
  end

endmodule
