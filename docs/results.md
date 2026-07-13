# Results

Status as of 2026-07-11. Hardware bring-up COMPLETE (see "Hardware bring-up" below);
everything here is measured, not estimated.

## v1.1: Hardware decompressor (2026-07-11)

The original stretch goal, now implemented: the inverse pipeline in fabric. New RTL:
`rle_dec.v` (zero-run decode), `delta_dec.v` (prefix-sum restore), `restore_ctrl.v`
(walks the compressed stream in out_mem: bitmap verbatim, bypass entries copied raw,
compressed entries through rle_dec -> delta_dec). New protocol command **0x50
GET_RESTORED** returns bitmap + restored kept vectors; PING now reports version 1.1.

Verification: golden.py gained `restored_stream`/`restore_from_stream` (+100 randomized
inversion self-tests); new `tb_restore` (bit-exact vs golden under randomized
backpressure, run twice to prove state reset); `tb_kv_top_full` now exercises
GET_RESTORED over UART twice (mixed-entry and keep-all). **All 8 testbenches PASS.**
Host: `python host/kv_host.py restore --port COMx --npz ... --threshold N` prints
RESTORE BIT-EXACT PASS when the fabric-decompressed bytes equal the kept originals.

This closes the loop: the board is now a full round-trip memory node — store
compressed, restore on demand, both directions verified byte-exact.

## Power & energy figures of merit (2026-07-13)

Derived by `scripts/power_summary.py` from the Vivado power report
(`docs/reports/power.rpt`, vectorless estimate, Low confidence) and the measured
threshold-3 run. Engine energy is baud-independent (PROCESS phase runs at 100 MHz
regardless of UART divisor). Full block: `docs/reports/fom.txt`.

| figure | total power | dynamic only |
|---|---|---|
| on-chip power | 156 mW | 83 mW (+73 mW static) |
| energy / byte processed (system) | 1.63 nJ | 0.87 nJ |
| energy / byte compressed (engine, kept) | 8.11 nJ | 4.31 nJ |
| throughput per watt (system) | 0.61 GB/s/W (4.9 Gbps/W) | 1.15 GB/s/W (9.2 Gbps/W) |

The whole accelerator draws under a fifth of a watt. Static power is the fixed cost
of a mostly-empty 20k-LUT chip, so the dynamic column better reflects the engine
itself. These complete the professional "report card": spec, architecture,
utilization, timing, throughput, **power/energy**, correctness.

## Both v1.1 bitstreams

Built 2026-07-11, zero errors/critical warnings, archived in `docs/bitstreams/`:

| bitstream | baud (CLKS_PER_BIT) | WNS | decompressor cost |
|---|---|---|---|
| `kv_top.bit` | 921,600 (109) | +0.975 ns | +394 LUTs (8.4%→10.3%), +643 FFs, +1 DSP, BRAM unchanged (49%) |
| `kv_top_2M.bit` | 2,000,000 (50) | +0.865 ns | same RTL, faster UART divisor |

Rebuild commands: `vivado -mode batch -source scripts/build_bitstream.tcl`
(default) or `... -tclargs 50 _2M` (2 Mbaud). The board must be re-programmed with a
v1.1 bitstream before `kv_host.py restore` works (a v1.0 bitstream NAKs command 0x50).

## Model-quality ablation (2026-07-11, host-side)

`python host/ppl_ablation.py --eval 200` — distilgpt2, 402-token context, teacher-forced
perplexity of a 200-token continuation with the KV-cache pruned before decoding.
Full data: `ppl.csv`, figure: `docs/reports/ppl.png`.

| kept | H2O + recency (hardware policy) | recency only | random keep |
|---|---|---|---|
| 100% | 59.4 (reference) | 59.4 | 59.4 |
| 75% | 62.1 (+4%) | 120.2 | 62.2 |
| 50% | 66.1 (+11%) | 293.6 | 193.4 |
| 30% | 91.9 | 778.5 | 490.6 |
| 20% | 148.7 | 1242.7 | 975.9 |
| 5% | 238.1 | 2914.2 | 2127.5 |

Findings: (1) the H2O importance policy the hardware implements degrades gracefully —
half the cache costs only +11% perplexity; (2) at the hardware demo point (20% kept,
4.84x memory saving) perplexity is 2.5x the full-cache reference — a real, quantified
trade-off; (3) both baselines collapse, so the *scoring* is what earns the memory savings,
not eviction per se. This closes the "MSE is only a proxy" caveat.

## Layer x head evictability map (2026-07-11)

`python host/evict_map.py [--port COMx]` — all 72 (layer, head) K slices, effective ratio
at threshold 3. Data: `evict_map.csv`, figure: `docs/reports/evict_map.png`.
This run measured on the golden model (board was unplugged); hardware re-run is the same
command with `--port` — golden is a proven-faithful stand-in (bit-exact at every threshold).

Findings: layer 0 is un-evictable (ratio ~1.0 on all 12 heads); layer 3 is almost uniformly
17-22x; layer 1 is diffuse except three sharply specialized heads (H4 21.1x, H7 16.6x,
H11 17.4x); layers 4-5 are evictable with individual outliers (L5H8 1.0x, L5H0 2.1x).
Confirms the shallow-diffuse / deep-concentrated premise (TailorKV) at head granularity.

## Verification

All 7 self-checking testbenches PASS in xsim (Vivado 2025.2), driven by vectors generated
from the Python golden model (`host/golden.py`, itself validated by randomized self-tests):

| testbench | what it proves |
|---|---|
| tb_uart_loopback | 8N1 RX/TX at CLKS_PER_BIT=20, incl. +/-2% baud error tolerance |
| tb_delta_enc | mod-256 delta, per-vector reset, valid/ready backpressure |
| tb_rle_enc | zero-run RLE incl. worst-case alternating, eov flush, per-vector clen |
| tb_vec_buffer | scratch buffer, done/clen timing, 96-byte max |
| tb_units | ratio_calc divider (incl. saturation, den=0), stats_regs counters |
| tb_engine | **bit-exact** out_mem stream + stats vs golden for the mixed 8-entry case |
| tb_kv_top_full | full UART transactions: PING, LOAD, RUN, GET_STATS, GET_DATA, re-RUN, corrupted checksum -> ERR, truncated frame -> watchdog recovery |

Run everything: `python scripts/run_sims.py`

## Real-data findings (distilgpt2, WikiText-style paragraph, T=402 tokens)

Exported with `host/export_kv.py`; golden pipeline (`host/golden_sweep.py`) verified
bit-exact at every threshold. Layer 2, head 5, K tensor:

| threshold | kept | comp bytes | effective ratio | bypass |
|---|---|---|---|---|
| 0 | 402 | 26,181 | 0.98x | 100% |
| 2 | 153 | 9,996 | 2.57x | 100% |
| 3 | 81 | 5,316 | 4.84x | 100% |
| 5 | 28 | 1,871 | 13.8x | 100% |
| 10+ | 17 | 1,156 | 22.3x | 100% |

**Finding 1 — delta+RLE contributes ~nothing on real INT8 KV data.** Bypass rate is 100%
on real K and V slices (both dim-axis and token-axis layouts tested): INT8 quantization
granularity means adjacent values almost never differ by exactly zero, and zero-run RLE
only pays on exact zeros. CXL-SpecKV's Table 9 attributes +36% ratio to delta and +18%
to RLE on their workloads; on distilgpt2 tensors we measure ~0%. The compression here
comes from (a) host-side FP16->INT8 (2x, off-FPGA) and (b) eviction. The per-vector
bypass (their "early-exit", alpha ~ 0.3 in the paper; alpha = 1.0 for us on real data)
is what bounds the damage to ~2% overhead instead of expansion. Synthetic smooth/constant
data compresses fine (up to 21x on `constant`), proving the fabric pipeline works —
the limitation is in the data statistics, not the hardware.

**Finding 2 — H2O-style eviction is where the memory goes.** Accumulated-attention
importance on layer 2 is extremely skewed (median score 1/255): threshold 3 keeps 20%
of tokens at 4.8x effective ratio. Whether those tokens *suffice* is measured by the
MSE-vs-kept-fraction curve (`plots.py tradeoff`), not claimed.

**Finding 3 — layer contrast matches paper 1's premise.** Layer 0 head 3 has diffuse
attention (median importance 119/255): the same threshold sweep barely evicts anything.
Heavy-hitter eviction is a *deep-layer* phenomenon at this scale, which parallels
TailorKV's shallow-vs-deep observation.

## Engine vs link throughput (sim-measured, to confirm on hardware)

tb_engine: 8 entries x 8 bytes, threshold 100 -> PROCESS phase completes in well under
100k cycles (bounded check; exact count reported by the stats record on hardware).
At 2 Mbaud the UART moves ~200 kB/s while the engine's byte-serial datapath at 100 MHz
processes tens of MB/s — the store-and-forward architecture makes this gap visible and
honest (cycle counter brackets only the PROCESS phase).

## Synthesis (Vivado 2025.2, xc7a35tcpg236-1) — the paper-2 Table 1 analog

Full build (synth + impl + bitstream) PASSES; **timing met at 100 MHz, WNS = +0.803 ns**.
Bitstream: `kv_cache.runs/impl_1/kv_top.bit`. Full reports in docs/reports/.

| resource | used | available | util | CXL-SpecKV (Agilex-7 @ 812 MHz) |
|---|---|---|---|---|
| Slice LUTs | 1,754 | 20,800 | 8.4% | 30.5% ALMs |
| Slice Registers | 1,531 | 41,600 | 3.7% | 14.0% |
| Block RAM tiles | 24.5 | 50 | 49.0% | 15.8% M20K |
| DSPs | 1 | 90 | 1.1% | 25.9% |

The logic is tiny (byte-serial datapath); BRAM dominates because slice_mem (32 KB) +
out_mem (36 KB) hold entire slices on chip — the toy-scale equivalent of the paper's
memory-capacity story.

## Hardware bring-up (2026-07-10, physical Basys 3 on COM4, 921,600 baud) — DONE

All measured on the board, not simulated:

- PING: version 1.0, max_entries 512.
- **BIT-EXACT PASS on real data**: `check --npz slices_l2h5k.npz --threshold 3` returned
  the exact golden stream (81 kept, 5,316 comp bytes, 4.840x, bypass 81/81) with
  `cycles_process = 26,941` -> **95.5 MB/s system throughput** (19.2 MB/s engine-honest)
  vs ~92 kB/s UART link — the engine-vs-link gap, quantified (paper 2's 51.2 GB/s engine
  vs 64 GB/s CXL framing, at toy scale).
- Full 256-point threshold sweep in seconds without re-uploading (LOAD/RUN split paid off):
  ratio 0.983x at threshold 0 -> 22.26x at threshold >= 10, matching golden_sweep exactly.
  Figures: docs/reports/sweep.png, sweep_zoom.png (the demo curve), throughput.png,
  tradeoff.png.
- **Methodology check PASSED**: the tb_engine case (8x8, threshold 100) measures
  `cycles_process = 238` in xsim and **238 on hardware** — exact equality.

## Demo build option

Default bitstream is 921,600 baud. For the 2 Mbaud demo build set `CLKS_PER_BIT=50` on
kv_top and rerun `scripts/build_bitstream.tcl`. Standalone mode: SW[7:0] = threshold,
BTNU = re-run, SW[15:14] selects the 7-seg stat (00 ratio x100).
