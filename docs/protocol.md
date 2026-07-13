# UART Protocol Specification (FROZEN)

Version 1.0.

## Physical layer

- 8N1 (8 data bits, no parity, 1 stop bit), no flow control (the FT2232HQ USB-serial bridge has no
  RTS/CTS wired to the FPGA).
- Baud plan at 100 MHz fabric clock (`CLKS_PER_BIT` is a synthesis parameter):
  - bring-up: **921,600** -> `CLKS_PER_BIT = 109` (-0.45% FPGA; FTDI +0.16%; safe)
  - demo:     **2,000,000** -> `CLKS_PER_BIT = 50` (exact on both ends)
  - do NOT use 3 Mbaud (divisor 33.33 -> >1% systematic error)
- Transaction model is **store-and-forward**: LOAD (host->FPGA into BRAM), PROCESS
  (engine runs BRAM-to-BRAM, cycle-counted), DRAIN (FPGA->host). No mid-stream
  backpressure exists or is needed: during LOAD the FSM consumes each byte in a few
  cycles out of the >=500-cycle byte period.

## Framing

Host -> FPGA:  `SOF=0xA5 | CMD[1] | LEN[2] (LE, payload bytes only) | PAYLOAD[LEN] | CKSUM[1]`
FPGA -> host:  `SOF=0x5A | (CMD|0x80)[1] | LEN[2] LE | PAYLOAD[LEN] | CKSUM[1]`

`CKSUM` = two's complement of (sum of CMD, LEN bytes, and PAYLOAD bytes) mod 256, i.e.
`(CMD + LEN_lo + LEN_hi + sum(PAYLOAD) + CKSUM) mod 256 == 0`. SOF is excluded.

Error response: `SOF 0x5A | 0xFF | LEN=1 | err_code | CKSUM` with codes:

| code | meaning |
|------|---------|
| 0x01 | checksum mismatch |
| 0x02 | malformed frame (LEN inconsistent with command, entry_count/vec_len out of range) |
| 0x03 | no slice loaded (RUN / GET_STATS / GET_DATA before a successful LOAD_SLICE) |
| 0x04 | unknown command |

Watchdog: if a partial frame stalls for 100 ms (10,000,000 cycles; parameter
`WATCHDOG_CYCLES`), the FSM silently discards it and returns to idle — no response is
sent (the host times out and retries once). A failed LOAD_SLICE (bad checksum) leaves
`slice_loaded = 0`: a partial upload invalidates any previous slice.

## Commands

| CMD  | Name         | Request payload | Response payload |
|------|--------------|-----------------|------------------|
| 0x01 | PING         | none            | `ver_major[1]=1, ver_minor[1]=1, max_entries[2] LE = 512` |
| 0x10 | LOAD_SLICE   | `entry_count[2] LE, vec_len[1], rsvd[1]=0`, then per entry: `imp[1], values[vec_len]` | `entries_stored[2] LE, status[1]=0` |
| 0x20 | RUN          | `mode[1], threshold[1]` | 24-byte stats record |
| 0x30 | GET_STATS    | none            | 24-byte stats record (from last RUN) |
| 0x40 | GET_DATA     | none            | compressed output stream (LEN = comp_bytes) |
| 0x50 | GET_RESTORED | none            | bitmap + RESTORED kept vectors (LEN = bm_len + entries_kept * vec_len) |

GET_RESTORED (v1.1, hardware decompressor): the FPGA walks the compressed stream in
out_mem and decompresses it in fabric — bypass entries are copied raw; compressed entries
go through zero-run RLE decode then delta decode. The response is the bitmap (verbatim,
`bm_len = (entry_count+7)>>3` bytes) followed by each kept entry's restored `vec_len`
original value bytes in ascending index order. Requires a completed RUN (else error 0x03).
Kept entries restore losslessly; evicted entries are gone (that is eviction's contract).

- LOAD_SLICE: `LEN` must equal `4 + entry_count*(1+vec_len)`; `1<=entry_count<=512`,
  `1<=vec_len<=64`, else error 0x02. Values for entry `i` are written to slice memory at
  address `{i[8:0], j[5:0]}` (fixed stride 64 regardless of vec_len).
- RUN: `mode` bit0 = 0 -> use `threshold` from payload; bit0 = 1 -> use switches SW[7:0]
  (threshold payload byte ignored). Other mode bits reserved = 0. LOAD and RUN are
  deliberately separate so a threshold sweep re-runs without re-uploading.
- A RUN can also be triggered on-board via BTNU (standalone mode): equivalent to
  RUN with mode=1, but no response frame is sent.

## Stats record (24 bytes, all little-endian)

| offset | field | size |
|--------|-------|------|
| 0  | status (0 = OK)      | 1 |
| 1  | entries_in           | 2 |
| 3  | entries_kept         | 2 |
| 5  | orig_bytes           | 4 |
| 9  | comp_bytes           | 4 |
| 13 | bypass_cnt           | 2 |
| 15 | cycles_process       | 4 |
| 19 | vec_len              | 1 |
| 20 | threshold_used       | 1 |
| 21 | reserved (0)         | 3 |

## Host rules

- pyserial: `timeout=1.0`, read exact expected byte counts, chunked writes are fine.
  FTDI latency timer (16 ms default) is irrelevant at these frame sizes.
- On NAK (0xFF response) or timeout: retry the whole frame once, then fail loudly.
