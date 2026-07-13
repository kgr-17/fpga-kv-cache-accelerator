"""Generate all simulation vector files under sim/vectors/ from the golden model.

Formats (FROZEN, see docs/interfaces.md):
- .hex files: one byte per line, two lowercase hex digits, $readmemh-compatible.
- <family>_in.hex     concatenated input vectors
  <family>_delta.hex  concatenated per-vector delta streams (same length as _in)
  <family>_rle.hex    concatenated per-vector RLE streams
  <family>_meta.hex   line0 = vec_len, line1 = nvec, then per-vector clen
- eng_*.hex           one full engine test case (slice memory image + expected out_mem)
- uart_*.hex          full-transaction byte streams (phase 1, then phase 2 after watchdog)
                      with compare masks (00 = skip byte, 01 = compare)
"""
import os
import random

import golden as g

HERE = os.path.dirname(os.path.abspath(__file__))
VEC_DIR = os.path.normpath(os.path.join(HERE, "..", "sim", "vectors"))


def write_hex(name, data):
    path = os.path.join(VEC_DIR, name)
    with open(path, "w") as f:
        for b in data:
            f.write(f"{b:02x}\n")
    return path


# ---------------------------------------------------------------- unit families

def smooth_vec(rng, L):
    v = [rng.randint(0, 255)]
    while len(v) < L:
        v.append((v[-1] + rng.randint(-2, 2)) & 0xFF)
    return bytes(v)


def altzero_vec(rng, L):
    """Vector whose deltas alternate 0, nonzero -> RLE worst case."""
    v = [rng.randint(0, 255)]
    step = 0
    while len(v) < L:
        if step % 2 == 0:
            v.append(v[-1])                                   # delta 0
        else:
            v.append((v[-1] + rng.randint(1, 255)) & 0xFF)    # delta != 0
        step += 1
    return bytes(v)


def make_families():
    rng = random.Random(1234)
    fams = {
        "constant": (64, [bytes([rng.randint(0, 255)] * 64) for _ in range(4)]),
        "ramp":     (64, [bytes(((i * k + 7) & 0xFF) for i in range(64)) for k in (1, 3, 254, 129)]),
        "random":   (64, [bytes(rng.randint(0, 255) for _ in range(64)) for _ in range(16)]),
        "smooth":   (64, [smooth_vec(rng, 64) for _ in range(16)]),
        "altzero":  (64, [altzero_vec(rng, 64) for _ in range(4)]),
        "len1":     (1,  [bytes([0]), bytes([9]), bytes([255]), bytes([128])]),
        # wraparound-heavy for the delta TB
        "wrap":     (64, [bytes(rng.choice([0, 1, 254, 255, 127, 128]) for _ in range(64))
                          for _ in range(8)]),
    }
    for fam, (L, vecs) in fams.items():
        cat_in, cat_d, cat_r, clens = bytearray(), bytearray(), bytearray(), []
        for v in vecs:
            d = g.delta_encode(v)
            r = g.rle_encode(d)
            assert g.delta_decode(d) == v and g.rle_decode(r) == d
            cat_in += v
            cat_d += d
            cat_r += r
            clens.append(len(r))
        write_hex(f"{fam}_in.hex", cat_in)
        write_hex(f"{fam}_delta.hex", cat_d)
        write_hex(f"{fam}_rle.hex", cat_r)
        write_hex(f"{fam}_meta.hex", bytes([L, len(vecs)] + clens))
        print(f"family {fam:9s}: {len(vecs)} vecs of len {L:2d}, "
              f"rle total {len(cat_r)}/{len(cat_in)} bytes")


# ---------------------------------------------------------------- engine case

def engine_slice():
    """8 entries x vec_len 8, threshold 100. Covers: evicted, compressible,
    all-zero, incompressible (bypass), clen==vec_len boundary (bypass), smooth."""
    rng = random.Random(99)
    nozero = bytearray([1])
    while len(nozero) < 8:                       # all deltas nonzero -> clen==8 -> bypass
        nxt = (nozero[-1] + rng.randint(1, 254)) & 0xFF
        if nxt == nozero[-1]:
            nxt = (nxt + 1) & 0xFF
        nozero.append(nxt)
    entries = [
        bytes([50] * 8),                         # kept, constant -> clen 3
        bytes([0] * 8),                          # evicted (imp low)
        bytes([0] * 8),                          # kept, all-zero -> clen 2
        bytes(rng.randint(0, 255) for _ in range(8)),   # kept, random -> likely bypass
        bytes(nozero),                           # kept, exact clen==8 boundary -> bypass
        smooth_vec(rng, 8),                      # kept, smooth
        bytes([7] * 8),                          # evicted
        bytes([1, 1, 1, 1, 200, 200, 200, 200]), # kept, two runs
    ]
    imps = [200, 10, 150, 190, 255, 101, 99, 100]
    return entries, imps, 8, 100


def make_engine_case():
    entries, imps, vec_len, threshold = engine_slice()
    n = len(entries)
    stream, stats = g.encode_stream(entries, imps, threshold)
    assert g.verify_roundtrip(entries, imps, threshold, stream)

    values = bytearray(g.MAX_ENTRIES * g.VAL_STRIDE)          # 32768, stride 64
    impmem = bytearray(g.MAX_ENTRIES)
    for i, (v, imp) in enumerate(zip(entries, imps)):
        values[i * g.VAL_STRIDE:i * g.VAL_STRIDE + vec_len] = v
        impmem[i] = imp
    write_hex("eng_values.hex", values)
    write_hex("eng_imp.hex", impmem)
    write_hex("eng_params.hex", bytes([n & 0xFF, n >> 8, vec_len, threshold]))
    write_hex("eng_expected.hex", stream)
    write_hex("eng_stats.hex",
              g.le16(stats["entries_kept"]) + g.le32(stats["orig_bytes"]) +
              g.le32(stats["comp_bytes"]) + g.le16(stats["bypass_cnt"]) + b"\x00")
    restored = g.restored_stream(entries, imps, threshold)
    assert restored == g.restore_from_stream(stream, n, vec_len)
    write_hex("eng_restored.hex", restored)
    print(f"engine case: kept {stats['entries_kept']}/{n}, "
          f"comp {stats['comp_bytes']}/{stats['orig_bytes']} B, "
          f"bypass {stats['bypass_cnt']}")
    return entries, imps, vec_len


# ---------------------------------------------------------------- uart case

def make_uart_case(entries, imps, vec_len):
    dev = g.DeviceModel()
    tx, rx, mask = bytearray(), bytearray(), []

    def step(frame, masked_stats=False, expect_response=True):
        tx.extend(frame)
        if not expect_response:
            return
        resp = dev.transact(bytes(frame))
        rx.extend(resp)
        mask.extend(g.stats_mask(len(resp)) if masked_stats else [1] * len(resp))

    step(g.build_frame(g.CMD_PING))
    step(g.build_frame(g.CMD_LOAD, g.load_payload(entries, imps, vec_len)))
    step(g.build_frame(g.CMD_RUN, bytes([0, 100])), masked_stats=True)
    step(g.build_frame(g.CMD_GET_STATS), masked_stats=True)
    step(g.build_frame(g.CMD_GET_DATA))
    step(g.build_frame(g.CMD_GET_RESTORED))         # fabric decompression, mixed entries
    step(g.build_frame(g.CMD_RUN, bytes([0, 0])), masked_stats=True)   # re-run, keep all
    step(g.build_frame(g.CMD_GET_DATA))
    step(g.build_frame(g.CMD_GET_RESTORED))         # keep-all restore
    bad = bytearray(g.build_frame(g.CMD_PING))
    bad[-1] ^= 0xFF                                            # corrupt checksum
    step(bytes(bad))                                           # expect ERR_CKSUM
    truncated = bytes([g.SOF_HOST, g.CMD_LOAD, 0x40, 0x00])    # dies mid-frame
    step(truncated, expect_response=False)                     # watchdog must clean up

    write_hex("uart_in.hex", tx)
    write_hex("uart_expected.hex", rx)
    write_hex("uart_mask.hex", bytes(mask))

    # phase 2: after watchdog expiry the link must have recovered
    tx2, rx2 = bytearray(), bytearray()
    f = g.build_frame(g.CMD_PING)
    tx2.extend(f)
    rx2.extend(dev.transact(f))
    write_hex("uart_in2.hex", tx2)
    write_hex("uart_expected2.hex", rx2)
    write_hex("uart_mask2.hex", bytes([1] * len(rx2)))
    print(f"uart case: phase1 {len(tx)} tx / {len(rx)} rx bytes "
          f"({mask.count(0)} masked), phase2 {len(tx2)}/{len(rx2)}")


if __name__ == "__main__":
    os.makedirs(VEC_DIR, exist_ok=True)
    make_families()
    e, i, vl = make_engine_case()
    make_uart_case(e, i, vl)
    print(f"PASS: all vectors written to {VEC_DIR}")
