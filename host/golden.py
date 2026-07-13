"""Golden reference model for the Basys 3 toy KV-cache optimizer.

Byte-exact implementation of docs/encoding.md and docs/protocol.md.
Hardware (RTL) and this file must never diverge: every testbench stimulus and
expected-output file is generated from here, and hardware-returned bytes are
verified against decode_stream()/verify_roundtrip().

Pure Python integers throughout (no numpy in the core) so that wrapping mod-256
arithmetic is explicit and platform-independent.
"""

MAX_ENTRIES = 512
VEC_MAX = 64
VAL_STRIDE = 64          # slice memory layout: entry i byte j at i*64 + j
OUT_MEM_DEPTH = 36864

SOF_HOST = 0xA5
SOF_DEV = 0x5A
CMD_PING = 0x01
CMD_LOAD = 0x10
CMD_RUN = 0x20
CMD_GET_STATS = 0x30
CMD_GET_DATA = 0x40
CMD_GET_RESTORED = 0x50
ERR_CKSUM = 0x01
ERR_MALFORMED = 0x02
ERR_NO_SLICE = 0x03
ERR_UNKNOWN_CMD = 0x04

VERSION = (1, 1)   # 1.1: GET_RESTORED (hardware decompressor)


# ---------------------------------------------------------------- encoding core

def quantize(x, scale=None):
    """FP list -> (int8-as-uint8 bytes, scale). Symmetric per-slice quantization."""
    if scale is None:
        m = max(abs(v) for v in x) if x else 0.0
        scale = m / 127.0 if m > 0 else 1.0
    q = []
    for v in x:
        r = int(round(v / scale))
        r = max(-127, min(127, r))
        q.append(r & 0xFF)          # two's complement byte
    return bytes(q), scale


def dequantize(b, scale):
    return [(v - 256 if v >= 128 else v) * scale for v in b]


def delta_encode(v):
    """d[0]=v[0]; d[i]=(v[i]-v[i-1]) mod 256."""
    out = bytearray()
    prev = 0
    for i, b in enumerate(v):
        out.append(b if i == 0 else (b - prev) & 0xFF)
        prev = b
    return bytes(out)


def delta_decode(d):
    out = bytearray()
    prev = 0
    for i, b in enumerate(d):
        prev = b if i == 0 else (prev + b) & 0xFF
        out.append(prev)
    return bytes(out)


def rle_encode(d):
    """Zero-run RLE: nonzero byte -> itself; run of n zeros -> 0x00, n. Per-vector."""
    out = bytearray()
    run = 0
    for b in d:
        if b == 0:
            run += 1
        else:
            if run:
                out += bytes([0x00, run])
                run = 0
            out.append(b)
    if run:
        out += bytes([0x00, run])
    return bytes(out)


def rle_decode(r):
    out = bytearray()
    i = 0
    while i < len(r):
        if r[i] == 0x00:
            assert i + 1 < len(r), "dangling zero-run marker"
            out += bytes(r[i + 1])
            i += 2
        else:
            out.append(r[i])
            i += 1
    return bytes(out)


def encode_entry(values):
    """One kept vector -> (HDR+payload bytes, bypassed?). See encoding.md."""
    L = len(values)
    assert 1 <= L <= VEC_MAX
    r = rle_encode(delta_encode(values))
    clen = len(r)
    if clen < L:
        return bytes([clen]) + r, False
    return bytes([0x80 | L]) + bytes(values), True


def decode_entry(stream, pos, vec_len):
    """Decode one entry at stream[pos:]. Returns (values, new_pos)."""
    hdr = stream[pos]
    pos += 1
    if hdr & 0x80:
        L = hdr & 0x7F
        assert L == vec_len, f"bypass length {L} != vec_len {vec_len}"
        return bytes(stream[pos:pos + L]), pos + L
    clen = hdr
    assert 1 <= clen < vec_len or (vec_len == 1 and False), \
        f"bad clen {clen} for vec_len {vec_len}"
    d = rle_decode(stream[pos:pos + clen])
    assert len(d) == vec_len, f"RLE decoded {len(d)} bytes, expected {vec_len}"
    return delta_decode(d), pos + clen


def bitmap_len(entry_count):
    return (entry_count + 7) >> 3


def encode_stream(entries, imps, threshold):
    """Full slice -> (output stream bytes, stats dict).

    entries: list of bytes objects (each vec_len long, all equal length)
    imps:    list of ints 0..255
    """
    n = len(entries)
    assert 1 <= n <= MAX_ENTRIES and len(imps) == n
    L = len(entries[0])
    assert all(len(e) == L for e in entries)
    keep = [imp >= threshold for imp in imps]
    bm = bytearray(bitmap_len(n))
    for i, k in enumerate(keep):
        if k:
            bm[i >> 3] |= 1 << (i & 7)
    out = bytearray(bm)
    bypass_cnt = 0
    for i in range(n):
        if keep[i]:
            enc, byp = encode_entry(entries[i])
            out += enc
            bypass_cnt += byp
    stats = {
        "entries_in": n,
        "entries_kept": sum(keep),
        "orig_bytes": n * L,
        "comp_bytes": len(out),
        "bypass_cnt": bypass_cnt,
        "vec_len": L,
        "threshold_used": threshold,
    }
    return bytes(out), stats


def decode_stream(stream, entry_count, vec_len):
    """Output stream -> dict {kept entry index: values bytes}. Consumes exactly len(stream)."""
    bl = bitmap_len(entry_count)
    bm = stream[:bl]
    pos = bl
    result = {}
    for i in range(entry_count):
        if bm[i >> 3] & (1 << (i & 7)):
            values, pos = decode_entry(stream, pos, vec_len)
            result[i] = values
    assert pos == len(stream), f"stream not fully consumed: {pos} != {len(stream)}"
    return result


def restored_stream(entries, imps, threshold):
    """Expected GET_RESTORED payload: bitmap + kept original vectors, ascending."""
    n = len(entries)
    keep = [imp >= threshold for imp in imps]
    bm = bytearray(bitmap_len(n))
    for i, k in enumerate(keep):
        if k:
            bm[i >> 3] |= 1 << (i & 7)
    return bytes(bm) + b"".join(bytes(entries[i]) for i in range(n) if keep[i])


def restore_from_stream(stream, entry_count, vec_len):
    """Software model of the hardware decompressor: compressed stream in,
    bitmap + restored kept vectors out. Must equal restored_stream()."""
    decoded = decode_stream(stream, entry_count, vec_len)
    bm = stream[:bitmap_len(entry_count)]
    return bytes(bm) + b"".join(decoded[i] for i in sorted(decoded))


def verify_roundtrip(entries, imps, threshold, stream):
    """Hard bit-exact check of a (possibly hardware-produced) stream. Raises on mismatch."""
    decoded = decode_stream(stream, len(entries), len(entries[0]))
    expect_kept = {i for i, imp in enumerate(imps) if imp >= threshold}
    assert set(decoded.keys()) == expect_kept, \
        f"kept set mismatch: {sorted(set(decoded) ^ expect_kept)}"
    for i in expect_kept:
        assert decoded[i] == bytes(entries[i]), f"entry {i} data mismatch"
    return True


# ---------------------------------------------------------------- protocol frames

def le16(v):
    return bytes([v & 0xFF, (v >> 8) & 0xFF])


def le32(v):
    return bytes([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF])


def rd16(b, o):
    return b[o] | (b[o + 1] << 8)


def rd32(b, o):
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)


def checksum(body):
    return (-sum(body)) & 0xFF


def build_frame(cmd, payload=b"", sof=SOF_HOST):
    body = bytes([cmd]) + le16(len(payload)) + bytes(payload)
    return bytes([sof]) + body + bytes([checksum(body)])


def build_response(cmd, payload=b""):
    return build_frame(cmd | 0x80, payload, sof=SOF_DEV)


def build_error(err_code):
    return build_frame(0xFF, bytes([err_code]), sof=SOF_DEV)


def parse_frame(raw, sof=SOF_DEV):
    """Validate and split a complete frame. Returns (cmd, payload)."""
    assert len(raw) >= 5, "frame too short"
    assert raw[0] == sof, f"bad SOF 0x{raw[0]:02X}"
    ln = rd16(raw, 2)
    assert len(raw) == 5 + ln, f"length mismatch: have {len(raw)}, LEN says {5 + ln}"
    assert sum(raw[1:]) & 0xFF == 0, "checksum mismatch"
    return raw[1], bytes(raw[4:4 + ln])


def load_payload(entries, imps, vec_len):
    p = bytearray(le16(len(entries)))
    p.append(vec_len)
    p.append(0)
    for imp, vals in zip(imps, entries):
        p.append(imp)
        p += vals
    return bytes(p)


def pack_stats(stats, cycles=0, status=0):
    """24-byte stats record per protocol.md."""
    r = bytearray(24)
    r[0] = status
    r[1:3] = le16(stats["entries_in"])
    r[3:5] = le16(stats["entries_kept"])
    r[5:9] = le32(stats["orig_bytes"])
    r[9:13] = le32(stats["comp_bytes"])
    r[13:15] = le16(stats["bypass_cnt"])
    r[15:19] = le32(cycles)
    r[19] = stats["vec_len"]
    r[20] = stats["threshold_used"]
    return bytes(r)


def unpack_stats(r):
    assert len(r) == 24
    return {
        "status": r[0],
        "entries_in": rd16(r, 1),
        "entries_kept": rd16(r, 3),
        "orig_bytes": rd32(r, 5),
        "comp_bytes": rd32(r, 9),
        "bypass_cnt": rd16(r, 13),
        "cycles_process": rd32(r, 15),
        "vec_len": r[19],
        "threshold_used": r[20],
    }

STATS_CYCLES_OFFSET = 15   # within the 24-byte record; frame offset = 4 + this


class DeviceModel:
    """Reference device: feed it host frames, get expected response bytes.

    For RUN/GET_STATS responses the cycles field is a placeholder (0) — mask it
    (plus that frame's checksum byte) when comparing against real hardware/RTL.
    """

    def __init__(self):
        self.entries = None
        self.imps = None
        self.vec_len = 0
        self.stream = None
        self.stats = None

    def ping_response(self):
        return build_response(CMD_PING, bytes([VERSION[0], VERSION[1]]) + le16(MAX_ENTRIES))

    def handle(self, cmd, payload):
        if cmd == CMD_PING:
            if payload:
                return build_error(ERR_MALFORMED)
            return self.ping_response()
        if cmd == CMD_LOAD:
            if len(payload) < 4:
                return build_error(ERR_MALFORMED)
            n = rd16(payload, 0)
            vl = payload[2]
            if not (1 <= n <= MAX_ENTRIES) or not (1 <= vl <= VEC_MAX) \
                    or len(payload) != 4 + n * (1 + vl):
                return build_error(ERR_MALFORMED)
            self.entries, self.imps = [], []
            pos = 4
            for _ in range(n):
                self.imps.append(payload[pos])
                self.entries.append(bytes(payload[pos + 1:pos + 1 + vl]))
                pos += 1 + vl
            self.vec_len = vl
            self.stream = self.stats = None
            return build_response(CMD_LOAD, le16(n) + b"\x00")
        if cmd == CMD_RUN:
            if len(payload) != 2:
                return build_error(ERR_MALFORMED)
            if self.entries is None:
                return build_error(ERR_NO_SLICE)
            threshold = payload[1]      # mode bit0=1 (switches) not modeled here
            self.stream, self.stats = encode_stream(self.entries, self.imps, threshold)
            return build_response(CMD_RUN, pack_stats(self.stats))
        if cmd == CMD_GET_STATS:
            if payload:
                return build_error(ERR_MALFORMED)
            if self.stats is None:
                return build_error(ERR_NO_SLICE)
            return build_response(CMD_GET_STATS, pack_stats(self.stats))
        if cmd == CMD_GET_DATA:
            if payload:
                return build_error(ERR_MALFORMED)
            if self.stream is None:
                return build_error(ERR_NO_SLICE)
            return build_response(CMD_GET_DATA, self.stream)
        if cmd == CMD_GET_RESTORED:
            if payload:
                return build_error(ERR_MALFORMED)
            if self.stream is None:
                return build_error(ERR_NO_SLICE)
            return build_response(
                CMD_GET_RESTORED,
                restore_from_stream(self.stream, len(self.entries), self.vec_len))
        return build_error(ERR_UNKNOWN_CMD)

    def transact(self, host_frame):
        """host_frame: full raw frame bytes. Returns expected device response bytes."""
        if sum(host_frame[1:]) & 0xFF != 0:
            return build_error(ERR_CKSUM)
        cmd = host_frame[1]
        ln = rd16(host_frame, 2)
        return self.handle(cmd, bytes(host_frame[4:4 + ln]))


def stats_mask(frame_len):
    """Compare-mask for a RUN/GET_STATS response frame: 0 = skip (cycles + cksum)."""
    m = [1] * frame_len
    for i in range(4):
        m[4 + STATS_CYCLES_OFFSET + i] = 0
    m[frame_len - 1] = 0
    return m


# ---------------------------------------------------------------- self-tests

def _selftest():
    import random
    rng = random.Random(0xC0FFEE)

    # delta round trip incl. wraparound-heavy values
    for _ in range(500):
        L = rng.randint(1, VEC_MAX)
        v = bytes(rng.choice([0, 1, 2, 127, 128, 254, 255, rng.randint(0, 255)])
                  for _ in range(L))
        assert delta_decode(delta_encode(v)) == v

    # rle round trip + directed edges
    cases = [
        bytes(64),                                   # all zeros -> 2 bytes
        bytes(range(1, 65)),                         # no zeros
        bytes([0, 5] * 32),                          # alternating worst case -> 96 bytes
        bytes([7] * 63 + [0]),                       # run ends exactly at eov
        bytes([0]),                                  # single zero, L=1
        bytes([9]),                                  # single nonzero, L=1
    ]
    assert len(rle_encode(cases[0])) == 2
    assert len(rle_encode(cases[2])) == 96
    for c in cases:
        assert rle_decode(rle_encode(c)) == c
    for _ in range(1000):
        L = rng.randint(1, VEC_MAX)
        d = bytes(rng.choice([0, 0, 0, rng.randint(0, 255)]) for _ in range(L))
        assert rle_decode(rle_encode(d)) == d

    # entry encode: bypass boundary
    v_allzero_delta = bytes([42] * 8)                # deltas: 42,0,0,... -> clen 3 < 8
    enc, byp = encode_entry(v_allzero_delta)
    assert not byp and enc[0] == 3
    v_random = bytes(rng.randint(1, 255) for _ in range(8))
    # ensure no zero deltas -> clen == 8 -> bypass
    v_nozero = bytearray([1])
    while len(v_nozero) < 8:
        v_nozero.append((v_nozero[-1] + rng.randint(1, 255)) & 0xFF)
        if v_nozero[-1] == v_nozero[-2]:             # would create zero delta
            v_nozero[-1] = (v_nozero[-1] + 1) & 0xFF
    enc, byp = encode_entry(bytes(v_nozero))
    assert byp and enc[0] == 0x88 and enc[1:] == bytes(v_nozero)

    # stream round trip, randomized
    for _ in range(200):
        n = rng.randint(1, 64)
        L = rng.randint(1, VEC_MAX)
        entries = [bytes(rng.randint(0, 255) for _ in range(L)) for _ in range(n)]
        imps = [rng.randint(0, 255) for _ in range(n)]
        thr = rng.randint(0, 255)
        stream, stats = encode_stream(entries, imps, thr)
        assert verify_roundtrip(entries, imps, thr, stream)
        assert stats["comp_bytes"] == len(stream)
        assert stats["comp_bytes"] <= bitmap_len(n) + stats["entries_kept"] * (1 + L)
    # threshold 0 keeps all
    stream, stats = encode_stream(entries, imps, 0)
    assert stats["entries_kept"] == stats["entries_in"]

    # frames
    f = build_frame(CMD_PING)
    assert sum(f[1:]) & 0xFF == 0 and f[0] == SOF_HOST
    cmd, pl = parse_frame(build_response(CMD_RUN, pack_stats(stats)), sof=SOF_DEV)
    assert cmd == (CMD_RUN | 0x80) and unpack_stats(pl)["entries_kept"] == stats["entries_kept"]

    # device model end-to-end
    dev = DeviceModel()
    entries = [bytes([10, 10, 10, 10]), bytes([1, 200, 3, 250]),
               bytes([0, 0, 0, 0]), bytes([5, 6, 7, 8])]
    imps = [200, 10, 150, 90]
    resp = dev.transact(build_frame(CMD_LOAD, load_payload(entries, imps, 4)))
    assert parse_frame(resp)[0] == (CMD_LOAD | 0x80)
    resp = dev.transact(build_frame(CMD_RUN, bytes([0, 100])))
    st = unpack_stats(parse_frame(resp)[1])
    assert st["entries_kept"] == 2 and st["orig_bytes"] == 16
    resp = dev.transact(build_frame(CMD_GET_DATA))
    _, stream = parse_frame(resp)
    assert verify_roundtrip(entries, imps, 100, stream)
    # restored stream: device-decompressed must equal bitmap + kept originals
    resp = dev.transact(build_frame(CMD_GET_RESTORED))
    _, restored = parse_frame(resp)
    assert restored == restored_stream(entries, imps, 100)
    # randomized: restore_from_stream inverts encode_stream for any slice
    for _ in range(100):
        n = rng.randint(1, 48)
        L = rng.randint(1, VEC_MAX)
        ents = [bytes(rng.randint(0, 255) for _ in range(L)) for _ in range(n)]
        ims = [rng.randint(0, 255) for _ in range(n)]
        thr = rng.randint(0, 255)
        strm, _ = encode_stream(ents, ims, thr)
        assert restore_from_stream(strm, n, L) == restored_stream(ents, ims, thr)
    # corrupted checksum
    bad = bytearray(build_frame(CMD_PING))
    bad[-1] ^= 0xFF
    assert parse_frame(dev.transact(bytes(bad)))[0] == 0xFF

    # quantize sanity
    q, s = quantize([0.5, -0.25, 1.0, -1.0])
    assert q == bytes([64, 256 - 32, 127, 256 - 127])

    print("PASS: golden.py self-tests")


if __name__ == "__main__":
    _selftest()
