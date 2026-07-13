# Results

Every figure below is measured — in simulation, or on the physical Artix-7 board where
noted — not estimated.

## Verification

Correctness is defined once in a Python **golden model** (`host/golden.py`, itself
validated by randomized self-tests), which generates every simulation vector. **Eight
self-checking Verilog testbenches** compare RTL output byte-for-byte
(`python scripts/run_sims.py`):

| testbench | what it proves |
|---|---|
| `tb_uart_loopback` | serial RX/TX, incl. ±2% baud-error tolerance |
| `tb_delta_enc` | mod-256 delta, per-vector reset, valid/ready backpressure |
| `tb_rle_enc` | zero-run RLE incl. worst-case alternating, flush, per-vector length |
| `tb_vec_buffer` | scratch buffer, done/length timing, 96-byte max |
| `tb_units` | ratio divider (saturation, divide-by-zero), stats counters |
| `tb_engine` | **bit-exact** output stream + stats vs. golden model |
| `tb_restore` | **bit-exact** fabric decompression vs. golden, under randomized backpressure |
| `tb_kv_top_full` | full host transactions: PING, LOAD, RUN, GET_STATS, GET_DATA, GET_RESTORED, corrupted-checksum → error, truncated-frame → watchdog recovery |

## Hardware bring-up — all measured on silicon

- **BIT-EXACT PASS on real data**: compressing a distilgpt2 KV slice returns the exact
  golden stream (81 of 402 tokens kept, 5,316 compressed bytes, 4.84× effective ratio,
  `cycles_process = 26,941` → **95.5 MB/s** engine throughput).
- **RESTORE BIT-EXACT PASS**: the hardware decompressor reconstructs every kept vector
  byte-for-byte from the stored compressed stream.
- **Simulation = silicon, cycle-exact**: the reference engine case measures an identical
  PROCESS cycle count in the simulator and on the board (238 = 238) — the performance
  numbers are exact, not modeled.
- A full **256-point threshold sweep** runs in seconds (load once, re-run per threshold),
  matching the golden model at every point.

## Hardware decompressor (full round trip)

The inverse pipeline is in fabric: `rle_dec` (zero-run decode) + `delta_dec` (prefix-sum
restore), sequenced by `restore_ctrl`, which walks the stored compressed stream and emits
the bitmap plus restored vectors. Protocol command `GET_RESTORED` returns them to the host.
The design is therefore a complete **round-trip memory node**: store compressed, restore
losslessly, both directions verified bit-exact.

## Compression vs. eviction threshold (distilgpt2 KV, layer 2 head 5, K)

| threshold | tokens kept | compressed bytes | effective ratio |
|---|---|---|---|
| 0 | 402 | 26,181 | 0.98× |
| 2 | 153 | 9,996 | 2.57× |
| 3 | 81 | 5,316 | 4.84× |
| 5 | 28 | 1,871 | 13.8× |
| 10+ | 17 | 1,156 | 22.3× |

**Findings:**

1. **Eviction carries the memory reduction.** Accumulated-attention importance on this
   layer is highly skewed, so a modest threshold retains a small fraction of tokens at a
   large effective ratio.
2. **Residual compression is data-limited, and safely so.** Delta + zero-run RLE yield
   little on quantized INT8 KV tensors — adjacent values rarely differ by exactly zero — so
   the per-vector **raw-bypass** safeguard bounds overhead to ~2% instead of expansion. The
   same pipeline compresses smooth/constant test data up to 21×, confirming the datapath is
   correct; the limitation is the statistics of the data, not the hardware.
3. **Evictability is structured by layer and head** (see the map below).

## Model-quality ablation

`python host/ppl_ablation.py` — distilgpt2, teacher-forced perplexity of a continuation
with the KV-cache pruned before decoding (figure: `docs/reports/ppl.png`):

| kept | importance policy (H2O + recency) | recency only | random |
|---|---|---|---|
| 100% | 59.4 (reference) | 59.4 | 59.4 |
| 75% | 62.1 (+4%) | 120.2 | 62.2 |
| 50% | 66.1 (+11%) | 293.6 | 193.4 |
| 30% | 91.9 | 778.5 | 490.6 |
| 20% | 148.7 | 1242.7 | 975.9 |
| 5% | 238.1 | 2914.2 | 2127.5 |

The importance policy degrades gracefully — **+11% perplexity at 50% retention** — while
recency-only and random baselines collapse. The *scoring* is what earns the savings, not
eviction alone.

## Layer / head evictability map

`python host/evict_map.py` — effective ratio at threshold 3 across all 72 (layer, head) K
slices (figure: `docs/reports/evict_map.png`). Layer 0 is near-incompressible across every
head; deeper layers are uniformly compressible (17–22×) with individual outliers.
Evictability concentrates in the deep layers — a per-head map of where KV-cache
optimization pays off.

## Implementation (Vivado, XC7A35T)

Full synthesis + implementation + bitstream; **timing met at 100 MHz**:

| resource | used | available | utilization |
|---|---|---|---|
| LUTs | 2,148 | 20,800 | 10.3% |
| Registers | 2,174 | 41,600 | 5.2% |
| Block RAM | 24.5 | 50 | 49.0% |
| DSP | 2 | 90 | 2.2% |
| **Fmax** | meets 100 MHz | | **WNS +0.98 ns** |

BRAM dominates because entire slices are held on-chip (32 KB input + 36 KB output):
memory, not logic, is the cost — matching the shape of the KV-cache problem itself.

## Power & energy figures of merit

From the Vivado power report (vectorless estimate) and the measured run
(`scripts/power_summary.py`, full block in `docs/reports/fom.txt`):

| figure | total power | dynamic only |
|---|---|---|
| on-chip power | 156 mW | 83 mW (+73 mW static) |
| energy / byte processed | 1.63 nJ | 0.87 nJ |
| throughput per watt | 0.61 GB/s/W (4.9 Gbps/W) | 1.15 GB/s/W (9.2 Gbps/W) |

The whole accelerator draws under a fifth of a watt.

## Build

Two bitstreams (serial host link at 921,600 or 2,000,000 baud); both meet timing.

```bash
vivado -mode batch -source scripts/build_bitstream.tcl            # default
vivado -mode batch -source scripts/build_bitstream.tcl -tclargs 50 _2M   # 2 Mbaud
python scripts/run_sims.py                                        # 8/8 PASS
```

Standalone board mode: `SW[7:0]` sets the eviction threshold, `BTNU` re-runs the loaded
slice, `SW[15:14]` selects the 7-segment readout (ratio / kept / bytes / cycles).
