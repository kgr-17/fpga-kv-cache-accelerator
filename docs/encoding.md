# Encoding Specification (FROZEN — hardware and golden model must match byte-exactly)

Version 1.0. Any change here requires re-verifying every testbench and the golden model.

## Data model

- **Entry** = one KV head-vector: `vec_len` value bytes (INT8, treated as raw uint8 by the
  pipeline) + 1 importance byte (uint8). `1 <= vec_len <= 64`.
- **Slice** = `entry_count` entries, `1 <= entry_count <= 512`.
- PC-side quantization (before upload, not on FPGA): per slice, symmetric scale
  `s = max(|X|) / 127`, `x_int8 = clip(round(x / s), -127, 127)`, stored as two's-complement
  bytes. The scale `s` stays on the host for reconstruction.

## Eviction

Entry `i` is **kept** iff `imp[i] >= threshold` (unsigned 8-bit compare).
`threshold = 0` keeps every entry (baseline). Top-K selection is done on the host by sending
the K-th score quantile as the threshold; the hardware only implements the compare.

## Delta encoding (per kept vector, length L = vec_len)

```
d[0] = v[0]
d[i] = (v[i] - v[i-1]) mod 256      for i in 1..L-1
```

All arithmetic on raw bytes with mod-256 wraparound. Each vector is self-contained (state
resets at every vector boundary). Inverse: `v[i] = (v[i-1] + d[i]) mod 256`.
Golden model MUST use wrapping uint8 arithmetic (`np.uint8`), never `np.int8`.

## Zero-run RLE (on the delta stream, per vector)

Scanning `d[0..L-1]` left to right:
- byte `b != 0x00` -> emit `b` (1 byte)
- maximal run of `n` consecutive `0x00` bytes (`1 <= n <= L <= 64`) -> emit `0x00, n` (2 bytes)
- runs never cross vector boundaries; a run in progress is flushed at end-of-vector

Consequences: `0x00` in the encoded stream is always a marker followed by a count byte.
Worst case (isolated zeros, e.g. alternating `0,x`): 64 input bytes -> 96 output bytes,
so intermediate output is bounded by 96 < 128 (scratch buffer size). `clen <= 96`.

## Per-vector bypass (early-exit)

Let `clen` = RLE output byte count for the vector. Emit one header byte
`HDR = {bypass[7], len[6:0]}`:

- `clen <  vec_len` -> `HDR = clen` (bypass=0), followed by the `clen` RLE bytes
- `clen >= vec_len` -> `HDR = 0x80 | vec_len` (bypass=1), followed by the `vec_len` RAW
  value bytes (original, pre-delta)

Worst case per kept entry: `1 + vec_len` bytes (<= 65). Hard bound on output size.

## Output stream layout

```
bitmap[bm_len]                      bm_len = ceil(entry_count / 8) = (entry_count + 7) >> 3
then for each KEPT entry, ascending index order:
  HDR (1 byte) + payload (clen or vec_len bytes)
```

Bitmap bit mapping: entry `i` -> byte `i >> 3`, bit `i & 7` (LSB-first). Bit = 1 means kept.
In `out_mem`, the bitmap occupies offsets `0 .. bm_len-1` and entry data starts at offset
`bm_len` (contiguous stream, no gap).

## Stats definitions

- `orig_bytes    = entry_count * vec_len` (values only; importance bytes are metadata,
  excluded from the ratio)
- `entries_kept  = number of kept entries`
- `comp_bytes    = bm_len + sum over kept entries of (1 + payload_len)`
- `bypass_cnt    = number of kept entries with bypass = 1`
- `cycles_process` = hardware cycle count of the PROCESS phase only (run_start .. run_done);
  not predicted by the golden model — testbenches assert plausibility bounds, and
  sim count must equal hardware count for identical input (same RTL).
- **Effective ratio = orig_bytes / comp_bytes** (the headline metric; composes eviction
  and compression)
- Two throughputs are reported: `orig_bytes / cycles_process` (system-level, credits
  eviction skipping) and `kept_bytes / cycles_process` (engine-honest,
  `kept_bytes = entries_kept * vec_len`)

## Worst-case sizes (entry_count=512, vec_len=64)

- input slice payload: `4 + 512*65 = 33,284` bytes
- output stream: `64 + 512*65 = 33,344` bytes (all kept, all bypass) -> out_mem = 36,864 B
