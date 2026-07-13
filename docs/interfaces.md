# RTL Module Interface Contracts (FROZEN)

Verilog-2001, one module per file in `rtl/`. Single clock domain: `clk` = 100 MHz board
clock, synchronous active-high `rst`. All strobes are 1-cycle unless stated. All BRAMs are
inferred (synchronous write, synchronous read with 1-cycle latency) — no IP cores.
`vec_buffer` uses distributed LUTRAM (async read).

Stream handshake used between engine pipeline stages: `data[7:0]`, `valid`, `ready`
(transfer on `valid && ready`), with `sov`/`eov`/`last` sidebands as noted. `eov`/`sov`
are asserted in the same cycle as the byte they annotate.

Constants: `MAX_ENTRIES=512`, `VEC_MAX=64`. Slice value layout: entry `i` byte `j` at
address `{i[8:0], j[5:0]}` (fixed stride 64). See docs/encoding.md and docs/protocol.md.

---

## uart_rx.v
```verilog
module uart_rx #(parameter CLKS_PER_BIT = 109) (
  input  wire       clk, rst,
  input  wire       i_rx,          // raw pin; 2-FF synchronizer INSIDE this module
  output reg  [7:0] o_data,
  output reg        o_valid        // 1-cycle strobe when a byte is received
);
```
8N1. Majority-of-3 sample at mid-bit (samples at counts mid-1, mid, mid+1). Resyncs on
each start-bit falling edge. Frame error (stop bit low): discard byte silently.

## uart_tx.v
```verilog
module uart_tx #(parameter CLKS_PER_BIT = 109) (
  input  wire       clk, rst,
  input  wire [7:0] i_data,
  input  wire       i_valid,
  output wire       o_ready,       // high when idle (can accept); transfer on valid&&ready
  output reg        o_tx           // idles high
);
```

## proto_ctrl.v
```verilog
module proto_ctrl #(parameter WATCHDOG_CYCLES = 10_000_000) (
  input  wire        clk, rst,
  // UART
  input  wire [7:0]  rx_data,   input wire rx_valid,
  output reg  [7:0]  tx_data,   output reg tx_valid,   input wire tx_ready,
  // slice load (write-through during LOAD_SLICE payload reception)
  output reg         ld_val_we, output reg [14:0] ld_val_addr, output reg [7:0] ld_val_data,
  output reg         ld_imp_we, output reg [8:0]  ld_imp_addr, output reg [7:0] ld_imp_data,
  // run control (single owner of run_start and threshold_used)
  output reg         run_start,                    // 1-cycle strobe
  output reg  [9:0]  cfg_entry_count,              // latched at successful LOAD (1..512)
  output reg  [6:0]  cfg_vec_len,                  // latched at successful LOAD (1..64)
  output reg  [7:0]  run_threshold,                // resolved (payload or sw) at RUN
  input  wire        run_done,                     // 1-cycle strobe from engine_ctrl
  input  wire        run_busy,
  input  wire [7:0]  sw_threshold,                 // SW[7:0]
  input  wire        btn_run,                      // debounced 1-cycle pulse from io_sync
  // stats (valid after run_done)
  input  wire [15:0] st_entries_in,  input wire [15:0] st_entries_kept,
  input  wire [31:0] st_orig_bytes,  input wire [31:0] st_comp_bytes,
  input  wire [15:0] st_bypass_cnt,  input wire [31:0] st_cycles,
  // out_mem read (synchronous: b_dout valid 1 cycle after b_addr)
  output reg  [15:0] rd_addr,   input wire [7:0] rd_data,
  // restore stream (v1.1: GET_RESTORED payload source, from restore_ctrl)
  output reg         rs_start,                     // strobe at dispatch
  input  wire [7:0]  rs_data,  input wire rs_valid,
  output wire        rs_ready,                     // comb: consuming this cycle
  // status
  output reg         slice_loaded,
  output reg  [3:0]  err_code,  output reg err_pulse
);
```
Implements docs/protocol.md exactly. `btn_run`: if `slice_loaded && !run_busy`, behaves as
RUN with mode=1 (threshold from switches) but sends no response frame. Checksum for
responses is accumulated while streaming. GET_DATA streams `st_comp_bytes` bytes from
out_mem starting at address 0.

## slice_mem.v
```verilog
module slice_mem (
  input  wire        clk,
  input  wire        a_we,   input wire [14:0] a_addr,   input wire [7:0] a_din,   // loader
  input  wire [14:0] b_addr, output reg  [7:0] b_dout,                              // engine
  input  wire        imp_we, input wire [8:0] imp_waddr, input wire [7:0] imp_din,
  input  wire [8:0]  imp_raddr, output reg [7:0] imp_dout
);
```
Values: 32768x8 (8 RAMB36). Importance: 512x8. Both synchronous-read, 1-cycle latency.
Internal array names are FROZEN for testbench hierarchical access/preload:
`slice_mem` value array = `mem`, importance array = `imp_mem`; `out_mem` array = `mem`.
The eviction compare (`evict_filter`) is instantiated INSIDE `engine_ctrl`.

## out_mem.v
```verilog
module out_mem (
  input  wire        clk,
  input  wire        a_we,   input wire [15:0] a_addr, input wire [7:0] a_din,  // engine
  input  wire [15:0] b_addr, output reg  [7:0] b_dout                            // proto DRAIN
);
```
Depth 36,864 (out-of-range addresses never occur by construction).

## evict_filter.v
```verilog
module evict_filter (
  input  wire [7:0] i_imp, input wire [7:0] i_thresh,
  output wire       o_keep       // combinational: i_imp >= i_thresh (unsigned)
);
```

## delta_enc.v
```verilog
module delta_enc (
  input  wire       clk, rst,
  input  wire [7:0] i_data, input wire i_valid, input wire i_sov, input wire i_eov,
  output wire       i_ready,
  output wire [7:0] o_data, output wire o_valid, output wire o_eov,
  input  wire       o_ready
);
```
Combinational pass-through of valid/ready/eov (`i_ready = o_ready`, `o_valid = i_valid`);
`o_data = i_sov ? i_data : (i_data - prev) mod 256`. `prev` register updates to `i_data`
on each accepted transfer (`i_valid && i_ready`).

## rle_enc.v
```verilog
module rle_enc (
  input  wire       clk, rst,
  input  wire [7:0] i_data, input wire i_valid, input wire i_eov,
  output wire       i_ready,      // deasserts while draining multi-byte emissions
  output reg  [7:0] o_data, output reg o_valid, output reg o_last,
  input  wire       o_ready
);
```
Zero-run encoder per docs/encoding.md. Consuming one input byte may emit 0..3 bytes
(zero-run marker pair before a nonzero byte, or flush at eov) over successive cycles;
at most 1 output byte per cycle. `o_last` marks the final output byte of the vector's
RLE stream. State fully resets after emitting `o_last`. Run counter max 64 (never
overflows: run length <= vec_len <= 64).

## vec_buffer.v
```verilog
module vec_buffer (
  input  wire       clk, rst,
  input  wire       clr,                          // strobe: reset write pointer for new vector
  input  wire [7:0] i_data, input wire i_valid, input wire i_last,   // always ready
  output reg  [7:0] o_clen,                       // byte count, valid when done pulses
  output reg        done,                         // 1-cycle strobe after i_last written
  input  wire [6:0] rd_addr, output wire [7:0] rd_data   // async LUTRAM read
);
```
128-byte distributed RAM scratch. Max legal clen = 96.

## stats_regs.v
```verilog
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
```
No multiplier: `orig_bytes` accumulates `vec_len` per `entry_inc`.

## ratio_calc.v
```verilog
module ratio_calc (
  input  wire        clk, rst,
  input  wire        start,          // strobe at run_done
  input  wire [31:0] num,            // orig_bytes
  input  wire [31:0] den,            // comp_bytes
  output reg  [15:0] ratio_x100,     // (num*100)/den, saturated at 9999; 0 if den==0
  output reg         done
);
```
Serial restoring divider (~40 cycles), runs once per RUN; display-only.

## engine_ctrl.v
```verilog
module engine_ctrl (
  input  wire        clk, rst,
  input  wire        i_start,                      // run_start
  input  wire [9:0]  i_entry_count, input wire [6:0] i_vec_len, input wire [7:0] i_thresh,
  output reg         o_busy, output reg o_done,    // o_done: 1-cycle strobe
  // slice_mem port B + importance read
  output reg  [14:0] val_addr,  input wire [7:0] val_data,
  output reg  [8:0]  imp_addr,  input wire [7:0] imp_data,
  // pipeline: engine drives delta_enc input; rle_enc output feeds vec_buffer (wired in kv_top)
  output reg  [7:0]  pipe_data, output reg pipe_valid, output reg pipe_sov, pipe_eov,
  input  wire        pipe_ready,                   // from delta_enc
  input  wire [7:0]  vb_clen,   input wire vb_done,
  output reg         vb_clr,
  output reg  [6:0]  vb_rd_addr, input wire [7:0] vb_rd_data,
  // out_mem write
  output reg         om_we, output reg [15:0] om_addr, output reg [7:0] om_din,
  // stats strobes
  output reg         st_entry_inc, st_kept_inc, st_bypass_inc,
  output reg         st_comp_set, output reg [31:0] st_comp_bytes
);
```
Sequencer per docs/encoding.md: for each entry read importance (sync, 1-cycle), evict or
stream the vector through delta->rle->vec_buffer, wait vb_done, write HDR then either
vec_buffer[0..clen-1] or raw re-read of slice_mem (bypass) to out_mem at write pointer
(starting at offset `bm_len = (entry_count+7)>>3`); keep bitmap in 512 FFs; after last
entry write bitmap bytes to out_mem[0..bm_len-1]; assert `st_comp_set` with final write
pointer, then `o_done`. Cycle count is measured by stats_regs via `cyc_en = o_busy`.

## delta_dec.v  (v1.1 decompressor)
```verilog
module delta_dec (
  input  wire       clk, rst,
  input  wire [7:0] i_data, input wire i_valid, input wire i_sov,
  output wire       i_ready,
  output wire [7:0] o_data, output wire o_valid,
  input  wire       o_ready
);
```
Inverse of delta_enc, combinational pass-through: `o_data = i_sov ? i_data : (i_data + prev)`;
`prev` updates to **o_data** (the restored value) on each accepted transfer.

## rle_dec.v  (v1.1 decompressor)
```verilog
module rle_dec (
  input  wire       clk, rst,
  input  wire       i_clr,            // strobe at vector start (defensive state reset)
  input  wire [7:0] i_data, input wire i_valid, output wire i_ready,
  output reg  [7:0] o_data, output reg o_valid, input wire o_ready
);
```
Inverse of rle_enc: literal byte -> itself; `0x00, n` -> n zero bytes (emitted over n
cycles, `i_ready` low while draining). At most 1 output byte per cycle.

## restore_ctrl.v  (v1.1 decompressor)
```verilog
module restore_ctrl (
  input  wire        clk, rst,
  input  wire        i_start,                  // strobe from proto_ctrl at dispatch
  input  wire [9:0]  i_entry_count, input wire [6:0] i_vec_len,
  output reg         o_active,                 // owns out_mem port B while high
  output reg  [15:0] om_addr, input wire [7:0] om_data,   // sync 1-cycle read
  output wire [7:0]  o_data, output wire o_valid, input wire o_ready,
  output reg         o_done                    // strobe after last byte accepted
);
```
Instantiates rle_dec + delta_dec internally. Walks out_mem: streams the bitmap verbatim
(latching it), then per kept entry parses HDR and either copies the raw payload
(bypass) or routes payload bytes through rle_dec -> delta_dec (`i_sov` = first restored
byte of the vector). Produces exactly `bm_len + entries_kept*vec_len` bytes.
kv_top muxes out_mem port B: `b_addr = o_active ? restore.om_addr : proto.rd_addr`.

## seg7_driver.v
```verilog
module seg7_driver (
  input  wire        clk, rst,
  input  wire [15:0] i_value,       // binary; displayed as 4 decimal digits (double-dabble),
  output reg  [6:0]  o_seg,         // saturate display at 9999; active-low segments CA..CG
  output reg  [3:0]  o_an           // active-low digit anodes, ~1 kHz scan
);
```

## io_sync.v
```verilog
module io_sync (
  input  wire        clk, rst,
  input  wire [15:0] i_sw,  output wire [15:0] o_sw,     // 2-FF sync
  input  wire        i_btnu, output wire o_btnu_pulse    // sync + ~1ms debounce + rising-edge pulse
);
```

## kv_top.v
```verilog
module kv_top #(parameter CLKS_PER_BIT = 109, parameter WATCHDOG_CYCLES = 10_000_000) (
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
```
Wires everything. Reset: btnC synchronized + 16-cycle power-on reset stretch.
Pipeline wiring: engine_ctrl.pipe_* -> delta_enc -> rle_enc -> vec_buffer (vec_buffer is
always ready: rle_enc.o_ready = 1).
LED map: 0 = RX activity (stretched ~10 ms), 1 = engine busy, 2 = TX activity,
3 = slice_loaded, 4 = error (stretched), 15:8 = SW[7:0] echo (threshold).
7-seg display source by SW[15:14]: 00 = ratio_x100, 01 = entries_kept, 10 = comp_bytes>>4,
11 = cycles>>10. All through seg7_driver.

---

## Testbench conventions (`sim/`)

Self-checking, **pure Verilog-2001** (no SystemVerilog — no `$fatal`, no `logic`):
print `PASS: <tb name>` exactly once at the end iff zero errors, else print
`FAIL: <tb name> <reason>` and `$finish`. Every TB must `$finish` on its own within a
bounded time (add a global timeout watchdog initial block that prints FAIL). Stimulus and expected data come from
`sim/vectors/*.hex` (one byte per line, two hex digits) generated by `host/make_vectors.py`
— regenerate with `python host/make_vectors.py`. Use `$readmemh` with **relative paths**
from the Vivado sim working directory; each TB takes a parameter `VEC_DIR` (default
`"../../../../sim/vectors"`) prepended to file names so xsim batch runs find them; the
Tcl/batch flow can override with `-testplusarg` alternatives if needed. Keep TB slices
small (8 entries x vec_len 8) so full-UART sims stay in seconds. Override `CLKS_PER_BIT=20`
and `WATCHDOG_CYCLES=4000` in UART-level TBs.

Vector file sets (generated; names frozen — see host/make_vectors.py):
- per-family delta/RLE unit vectors: `<family>_in.hex`, `<family>_delta.hex`, `<family>_rle.hex`
  (+ `<family>_meta.hex`: line0 = vec_len, line1 = nvec, then per-vector clen).
  Families: constant, ramp, random, smooth, altzero (RLE worst case), len1, wrap
  (wraparound-heavy for delta). tb_delta_enc compares `_in` -> `_delta`;
  tb_rle_enc feeds `_delta` and compares -> `_rle` (with `_meta` clens).
- engine test case: `eng_values.hex` (32768 lines), `eng_imp.hex` (512), `eng_params.hex`
  (4 lines: entry_count_lo, entry_count_hi, vec_len, threshold), `eng_expected.hex`
  (expected out_mem contents, comp_bytes lines), `eng_stats.hex` (13 lines: LE bytes of
  entries_kept[2], orig_bytes[4], comp_bytes[4], bypass_cnt[2], and status[1]=0),
  `eng_restored.hex` (expected GET_RESTORED stream: bitmap + kept original vectors —
  consumed by tb_restore, which preloads out_mem with eng_expected.hex)
- full-UART test case: `uart_in.hex` (all bytes the host sends, in order),
  `uart_expected.hex` (all bytes the device must reply, in order)
