`timescale 1ns/1ps
// tb_uart_loopback — self-checking TB for uart_tx / uart_rx, CLKS_PER_BIT=20.
// Test 1: tx.o_tx wired to rx.i_rx; 300 random bytes with a mix of
//         back-to-back sends and random 0..100 cycle gaps.
// Test 2: rx.i_rx driven directly by a behavioral task with off-nominal
//         bit periods of 196 ns and 204 ns (nominal 200 ns, i.e. +/-2%),
//         100 random bytes each.
// Reproducible: all randomness from $random with a fixed seed variable.
module tb_uart_loopback;

  // Per TB convention every bench takes VEC_DIR; this bench uses generated
  // random stimulus, so no vector files are loaded.
  parameter VEC_DIR = "../../../../sim/vectors";

  localparam CLKS_PER_BIT = 20;    // 20 clocks @ 10 ns => 200 ns nominal bit

  reg        clk, rst;
  reg  [7:0] tx_data;
  reg        tx_valid;
  wire       tx_ready, tx_line;
  wire [7:0] rx_data;
  wire       rx_valid;

  reg        use_direct;           // 0: rx fed from tx_line; 1: behavioral driver
  reg        direct_rx;
  wire       rx_in = use_direct ? direct_rx : tx_line;

  uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
    .clk(clk), .rst(rst),
    .i_data(tx_data), .i_valid(tx_valid), .o_ready(tx_ready), .o_tx(tx_line)
  );

  uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
    .clk(clk), .rst(rst),
    .i_rx(rx_in), .o_data(rx_data), .o_valid(rx_valid)
  );

  // 100 MHz clock
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // global timeout watchdog
  initial begin
    #200_000_000;
    $display("FAIL: tb_uart_loopback global timeout");
    $finish;
  end

  // in-order scoreboard: sender queues expected bytes, checker pops them
  reg [7:0] exp_q [0:511];
  integer   send_idx, recv_idx;
  integer   seed;

  always @(posedge clk) begin
    if (!rst && rx_valid) begin
      if (recv_idx >= send_idx) begin
        $display("FAIL: tb_uart_loopback unexpected byte 0x%02x (nothing outstanding)", rx_data);
        $finish;
      end
      if (rx_data !== exp_q[recv_idx]) begin
        $display("FAIL: tb_uart_loopback byte %0d: got 0x%02x expected 0x%02x",
                 recv_idx, rx_data, exp_q[recv_idx]);
        $finish;
      end
      recv_idx = recv_idx + 1;
    end
  end

  // send one byte through uart_tx: hold i_valid until accepted on valid&&ready
  task tx_send;
    input [7:0] b;
    begin
      @(negedge clk);
      tx_data  = b;
      tx_valid = 1'b1;
      @(posedge clk);
      while (tx_ready !== 1'b1) @(posedge clk);  // loop exits at the accepting edge
      @(negedge clk);
      tx_valid = 1'b0;
    end
  endtask

  // drive one 8N1 byte directly on rx_in with an arbitrary bit period in ns
  task rx_drive_byte;
    input [7:0]   b;
    input integer bit_ns;
    integer k;
    begin
      direct_rx = 1'b0;                          // start bit
      #(bit_ns);
      for (k = 0; k < 8; k = k + 1) begin
        direct_rx = b[k];                        // LSB first
        #(bit_ns);
      end
      direct_rx = 1'b1;                          // stop bit
      #(bit_ns);
    end
  endtask

  // nbytes random bytes at bit_ns, mostly back-to-back, occasional 1-2 bit gaps
  task rx_drive_batch;
    input integer nbytes;
    input integer bit_ns;
    integer j, g;
    reg [7:0] bb;
    begin
      for (j = 0; j < nbytes; j = j + 1) begin
        bb = $random(seed);
        exp_q[send_idx] = bb;
        send_idx = send_idx + 1;
        rx_drive_byte(bb, bit_ns);
        if (({$random(seed)} % 4) == 0) begin
          g = 1 + ({$random(seed)} % 2);
          #(bit_ns * g);
        end
      end
    end
  endtask

  integer i, gap;
  reg [7:0] b;

  initial begin
    seed       = 32'h5EED0001;    // fixed seed: run is fully reproducible
    rst        = 1'b1;
    tx_data    = 8'h00;
    tx_valid   = 1'b0;
    use_direct = 1'b0;
    direct_rx  = 1'b1;
    send_idx   = 0;
    recv_idx   = 0;
    repeat (10) @(posedge clk);
    rst = 1'b0;
    repeat (10) @(posedge clk);

    // ---- Test 1: TX -> RX loopback, 300 random bytes, mixed gaps ----
    for (i = 0; i < 300; i = i + 1) begin
      b = $random(seed);
      exp_q[send_idx] = b;
      send_idx = send_idx + 1;
      tx_send(b);
      if (({$random(seed)} % 2) == 0)
        gap = 0;                                 // back-to-back
      else
        gap = {$random(seed)} % 101;             // 0..100 idle cycles
      repeat (gap) @(posedge clk);
    end
    wait (recv_idx == 300);

    // ---- Test 2: direct behavioral drive with +/-2% baud error ----
    repeat (100) @(posedge clk);                 // let the line idle high
    use_direct = 1'b1;
    repeat (100) @(posedge clk);

    rx_drive_batch(100, 196);                    // -2% (fast sender)
    wait (recv_idx == 400);
    repeat (100) @(posedge clk);

    rx_drive_batch(100, 204);                    // +2% (slow sender)
    wait (recv_idx == 500);

    repeat (100) @(posedge clk);
    $display("PASS: tb_uart_loopback");
    $finish;
  end

endmodule
