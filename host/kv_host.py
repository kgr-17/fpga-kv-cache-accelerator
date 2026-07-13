#!/usr/bin/env python3
"""Host-side CLI for the Basys 3 toy KV-cache optimizer.

Speaks docs/protocol.md over pyserial. All framing / encoding / verification
logic is reused from golden.py (the byte-exact reference model) so the CLI can
never drift from the spec. Python 3.9 compatible.

Usage examples:
  python kv_host.py selftest
  python kv_host.py --port COM4 ping
  python kv_host.py --port COM4 check --npz slices.npz --quantile 0.75
  python kv_host.py --port COM4 check --synthetic smooth:256:64 --threshold 100
  python kv_host.py --port COM4 sweep --npz slices.npz --out sweep.csv
"""
import argparse
import csv
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import golden as g


class LinkError(Exception):
    """Unrecoverable link failure (after the single protocol-mandated retry)."""


class LinkTimeout(LinkError):
    """Timeout / short read while waiting for a response (retryable)."""


# ------------------------------------------------------------------ serial link

SOF_HUNT_LIMIT = 4096   # max garbage bytes to skip while hunting for SOF


class SerialLink:
    """Framed request/response link per docs/protocol.md.

    Wraps any object with pyserial's read/write interface, so the selftest can
    substitute an in-process golden.DeviceModel shim for real hardware.
    Host rule: on timeout or NAK, retry the whole exchange once, then fail loudly.
    """

    def __init__(self, ser):
        self.ser = ser

    @classmethod
    def open(cls, port, baud=921600, timeout=1.0):
        import serial   # deferred import: selftest must run without pyserial
        return cls(serial.Serial(port=port, baudrate=baud, timeout=timeout))

    def close(self):
        if hasattr(self.ser, "close"):
            self.ser.close()

    def send_frame(self, cmd, payload=b""):
        self.ser.write(g.build_frame(cmd, bytes(payload)))

    def _read_exact(self, n):
        """Read exactly n bytes; the per-chunk timeout is the serial timeout."""
        buf = bytearray()
        while len(buf) < n:
            chunk = self.ser.read(n - len(buf))
            if not chunk:
                raise LinkTimeout(f"timeout: got {len(buf)}/{n} payload bytes")
            buf += chunk
        return bytes(buf)

    def read_response(self):
        """Hunt for SOF 0x5A, read the header, then LEN payload + checksum.

        Returns (cmd, payload). Raises LinkTimeout/LinkError on trouble.
        """
        for _ in range(SOF_HUNT_LIMIT):
            b = self.ser.read(1)
            if not b:
                raise LinkTimeout("timeout waiting for SOF")
            if b[0] == g.SOF_DEV:
                break
        else:
            raise LinkError(f"no SOF 0x5A within {SOF_HUNT_LIMIT} bytes")
        hdr = self._read_exact(3)                       # CMD, LEN_lo, LEN_hi
        ln = hdr[1] | (hdr[2] << 8)
        rest = self._read_exact(ln + 1)                 # payload + checksum
        # CMD + LEN bytes + payload + cksum must sum to 0 mod 256 (SOF excluded)
        if (sum(hdr) + sum(rest)) & 0xFF != 0:
            raise LinkTimeout("response checksum mismatch")
        return hdr[0], rest[:ln]

    def transact(self, cmd, payload=b""):
        """Send a frame, return the response payload. One retry on timeout/NAK."""
        last_err = "unknown"
        for attempt in range(2):
            if attempt and hasattr(self.ser, "reset_input_buffer"):
                self.ser.reset_input_buffer()           # drop stale bytes before retry
            try:
                self.send_frame(cmd, payload)
                rcmd, rpay = self.read_response()
            except LinkTimeout as e:
                last_err = str(e)
                continue
            if rcmd == 0xFF:                            # NAK
                code = rpay[0] if rpay else -1
                last_err = f"NAK err_code=0x{code:02X}"
                continue
            if rcmd != ((cmd | 0x80) & 0xFF):
                raise LinkError(
                    f"unexpected response cmd 0x{rcmd:02X} to request 0x{cmd:02X}")
            return rpay
        raise LinkError(f"command 0x{cmd:02X} failed after retry: {last_err}")


class DeviceModelSerial:
    """pyserial-compatible shim backed by golden.DeviceModel (for selftest).

    write() accumulates host bytes, transacts complete frames through the
    golden model, and queues the response bytes for read().
    """

    def __init__(self):
        self.dev = g.DeviceModel()
        self._host_buf = bytearray()    # host -> device, pending frame bytes
        self.txbuf = bytearray()        # device -> host, awaiting read()

    def write(self, data):
        self._host_buf += data
        while True:
            while self._host_buf and self._host_buf[0] != g.SOF_HOST:
                del self._host_buf[0]
            if len(self._host_buf) < 4:
                return len(data)
            ln = self._host_buf[2] | (self._host_buf[3] << 8)
            total = 5 + ln
            if len(self._host_buf) < total:
                return len(data)
            frame = bytes(self._host_buf[:total])
            del self._host_buf[:total]
            self.txbuf += self.dev.transact(frame)

    def read(self, n=1):
        out = bytes(self.txbuf[:n])     # short read == timeout, like pyserial
        del self.txbuf[:n]
        return out

    def reset_input_buffer(self):
        self.txbuf.clear()

    def close(self):
        pass


# ------------------------------------------------------------------ slice sources

def synth_slice(spec):
    """FAMILY:N:LEN -> (entries, imps, vec_len, scale, meta). Fixed seed."""
    parts = spec.split(":")
    if len(parts) != 3:
        raise SystemExit(f"bad --synthetic spec '{spec}', expected FAMILY:N:LEN")
    fam = parts[0]
    try:
        n, vec_len = int(parts[1]), int(parts[2])
    except ValueError:
        raise SystemExit(f"bad --synthetic spec '{spec}', N and LEN must be integers")
    if not (1 <= n <= g.MAX_ENTRIES):
        raise SystemExit(f"synthetic N={n} out of range 1..{g.MAX_ENTRIES}")
    if not (1 <= vec_len <= g.VEC_MAX):
        raise SystemExit(f"synthetic LEN={vec_len} out of range 1..{g.VEC_MAX}")
    rng = random.Random(0xBA5EBA11)     # fixed seed: reproducible slices
    entries = [_synth_vec(fam, rng, vec_len) for _ in range(n)]
    imps = [rng.randint(0, 255) for _ in range(n)]
    return entries, imps, vec_len, 1.0, f"synthetic:{spec}"


def _synth_vec(fam, rng, L):
    # Same generator styles as host/make_vectors.py unit families.
    if fam == "constant":
        return bytes([rng.randint(0, 255)] * L)
    if fam == "ramp":
        k, off = rng.randint(1, 255), rng.randint(0, 255)
        return bytes(((i * k + off) & 0xFF) for i in range(L))
    if fam == "random":
        return bytes(rng.randint(0, 255) for _ in range(L))
    if fam == "smooth":
        v = [rng.randint(0, 255)]
        while len(v) < L:
            v.append((v[-1] + rng.randint(-2, 2)) & 0xFF)
        return bytes(v)
    raise SystemExit(
        f"unknown synthetic family '{fam}' (use constant/ramp/random/smooth)")


def npz_slice(path):
    """Load a slice produced by export_kv.py -> (entries, imps, vec_len, scale, meta)."""
    import numpy as np
    d = np.load(path)
    values = np.asarray(d["values"], dtype=np.uint8)
    if values.ndim != 2:
        raise SystemExit(f"{path}: 'values' must be 2-D [n, vec_len]")
    n, vec_len = values.shape
    if not (1 <= n <= g.MAX_ENTRIES) or not (1 <= vec_len <= g.VEC_MAX):
        raise SystemExit(f"{path}: slice shape {n}x{vec_len} out of device range")
    entries = [values[i].tobytes() for i in range(n)]
    imps = [int(x) & 0xFF for x in np.asarray(d["imps"], dtype=np.uint8).tolist()]
    if len(imps) != n:
        raise SystemExit(f"{path}: imps length {len(imps)} != entry count {n}")
    scale = float(d["scale"])
    meta = str(d["meta"]) if "meta" in d.files else ""
    return entries, imps, vec_len, scale, meta


def resolve_slice(args):
    if getattr(args, "npz", None):
        return npz_slice(args.npz)
    return synth_slice(args.synthetic)


def quantile_threshold(imps, q):
    """Q-th quantile of the importance scores (nearest-rank on sorted values).

    Keeping entries with imp >= threshold approximates keeping the top (1-Q)
    fraction, i.e. the host-side top-K mapping from docs/encoding.md.
    """
    if not (0.0 <= q <= 1.0):
        raise SystemExit(f"--quantile {q} out of range 0..1")
    s = sorted(imps)
    idx = int(round(q * (len(s) - 1)))
    return s[idx]


# ------------------------------------------------------------------ subcommands

def print_stats(st):
    comp = st["comp_bytes"]
    ratio = st["orig_bytes"] / comp if comp else float("inf")
    kept_bytes = st["entries_kept"] * st["vec_len"]
    print(f"  status          : {st['status']}")
    print(f"  entries_in      : {st['entries_in']}")
    print(f"  entries_kept    : {st['entries_kept']}")
    print(f"  orig_bytes      : {st['orig_bytes']}")
    print(f"  comp_bytes      : {comp}")
    print(f"  bypass_cnt      : {st['bypass_cnt']}")
    print(f"  cycles_process  : {st['cycles_process']}")
    print(f"  vec_len         : {st['vec_len']}")
    print(f"  threshold_used  : {st['threshold_used']}")
    print(f"  effective ratio : {ratio:.3f}x")
    if st["cycles_process"]:
        c = st["cycles_process"]
        print(f"  throughput      : {st['orig_bytes'] / c * 100e6 / 1e6:.1f} MB/s "
              f"(orig), {kept_bytes / c * 100e6 / 1e6:.1f} MB/s (kept)")


def do_load(link, entries, imps, vec_len):
    pay = link.transact(g.CMD_LOAD, g.load_payload(entries, imps, vec_len))
    if len(pay) != 3 or g.rd16(pay, 0) != len(entries) or pay[2] != 0:
        raise LinkError(f"LOAD_SLICE bad response payload: {pay.hex()}")


def cmd_ping(link, args):
    pay = link.transact(g.CMD_PING)
    if len(pay) != 4:
        raise LinkError(f"PING bad response payload: {pay.hex()}")
    print(f"device version {pay[0]}.{pay[1]}, max_entries {g.rd16(pay, 2)}")
    return 0


def cmd_check(link, args):
    entries, imps, vec_len, scale, meta = resolve_slice(args)
    if args.quantile is not None:
        threshold = quantile_threshold(imps, args.quantile)
        print(f"threshold {threshold} (quantile {args.quantile} of imps)")
    else:
        threshold = args.threshold
        if not (0 <= threshold <= 255):
            raise SystemExit(f"--threshold {threshold} out of range 0..255")
        print(f"threshold {threshold}")
    print(f"slice: {len(entries)} entries x vec_len {vec_len}, "
          f"scale {scale:.6g}, meta '{meta}'")

    do_load(link, entries, imps, vec_len)
    st = g.unpack_stats(link.transact(g.CMD_RUN, bytes([0, threshold])))
    st2 = g.unpack_stats(link.transact(g.CMD_GET_STATS))
    if st2 != st:
        print(f"WARNING: GET_STATS record differs from RUN record: {st2}")
    stream = link.transact(g.CMD_GET_DATA)

    print("stats:")
    print_stats(st)
    ok = True
    if st["status"] != 0:
        print(f"BIT-EXACT FAIL: device status {st['status']}")
        ok = False
    if ok and len(stream) != st["comp_bytes"]:
        print(f"BIT-EXACT FAIL: GET_DATA length {len(stream)} != "
              f"comp_bytes {st['comp_bytes']}")
        ok = False
    if ok:
        try:
            g.verify_roundtrip(entries, imps, threshold, stream)
        except AssertionError as e:
            print(f"BIT-EXACT FAIL: {e}")
            ok = False
    if ok:
        print("BIT-EXACT PASS")
    return 0 if ok else 1


def cmd_restore(link, args):
    """LOAD, RUN, then GET_RESTORED: the FPGA decompresses in fabric and the
    result must equal bitmap + kept original vectors, byte for byte."""
    entries, imps, vec_len, scale, meta = resolve_slice(args)
    if args.quantile is not None:
        threshold = quantile_threshold(imps, args.quantile)
        print(f"threshold {threshold} (quantile {args.quantile} of imps)")
    else:
        threshold = args.threshold
        if not (0 <= threshold <= 255):
            raise SystemExit(f"--threshold {threshold} out of range 0..255")
        print(f"threshold {threshold}")
    print(f"slice: {len(entries)} entries x vec_len {vec_len}, meta '{meta}'")

    do_load(link, entries, imps, vec_len)
    st = g.unpack_stats(link.transact(g.CMD_RUN, bytes([0, threshold])))
    restored = link.transact(g.CMD_GET_RESTORED)
    expected = g.restored_stream(entries, imps, threshold)

    kept_bytes = st["entries_kept"] * vec_len
    print(f"kept {st['entries_kept']}/{st['entries_in']} entries; "
          f"restored payload {len(restored)} bytes "
          f"(bitmap {g.bitmap_len(len(entries))} + {kept_bytes} restored)")
    if restored == expected:
        print("RESTORE BIT-EXACT PASS (decompressed in fabric)")
        return 0
    n = min(len(restored), len(expected))
    diff = next((i for i in range(n) if restored[i] != expected[i]), n)
    print(f"RESTORE FAIL: first difference at byte {diff} "
          f"(got {len(restored)} bytes, expected {len(expected)})")
    return 1


def sweep_thresholds(points):
    if points >= 256:
        return list(range(256))
    if points <= 1:
        return [0]
    return sorted(set(int(round(i * 255.0 / (points - 1))) for i in range(points)))


def cmd_sweep(link, args):
    entries, imps, vec_len, scale, meta = resolve_slice(args)
    print(f"slice: {len(entries)} entries x vec_len {vec_len}, meta '{meta}'")
    do_load(link, entries, imps, vec_len)

    thresholds = sweep_thresholds(args.points)
    rows = []
    for t in thresholds:
        st = g.unpack_stats(link.transact(g.CMD_RUN, bytes([0, t])))
        if st["status"] != 0:
            raise LinkError(f"RUN threshold {t}: device status {st['status']}")
        comp = st["comp_bytes"]
        rows.append({
            "threshold": t,
            "entries_kept": st["entries_kept"],
            "orig_bytes": st["orig_bytes"],
            "comp_bytes": comp,
            "ratio": round(st["orig_bytes"] / comp, 4) if comp else 0.0,
            "bypass_cnt": st["bypass_cnt"],
            "cycles": st["cycles_process"],
        })

    fields = ["threshold", "entries_kept", "orig_bytes", "comp_bytes",
              "ratio", "bypass_cnt", "cycles"]
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)

    print(f"{'thr':>4} {'kept':>5} {'orig_B':>8} {'comp_B':>8} "
          f"{'ratio':>8} {'bypass':>6} {'cycles':>9}")
    step = max(1, len(rows) // 16)      # sample ~16 rows for the console table
    shown = rows[::step]
    if shown[-1] is not rows[-1]:
        shown.append(rows[-1])
    for r in shown:
        print(f"{r['threshold']:>4} {r['entries_kept']:>5} {r['orig_bytes']:>8} "
              f"{r['comp_bytes']:>8} {r['ratio']:>8.3f} {r['bypass_cnt']:>6} "
              f"{r['cycles']:>9}")
    print(f"wrote {len(rows)} rows to {args.out}")
    return 0


def cmd_selftest(args):
    """Full CLI-vs-golden transaction, no hardware. Validates framing logic."""
    try:
        shim = DeviceModelSerial()
        link = SerialLink(shim)

        # 1. PING round trip
        pay = link.transact(g.CMD_PING)
        assert pay == bytes([g.VERSION[0], g.VERSION[1]]) + g.le16(g.MAX_ENTRIES), \
            f"bad PING payload {pay.hex()}"

        # 2. LOAD / RUN / GET_STATS / GET_DATA on a synthetic slice, bit-exact
        entries, imps, vec_len, _, _ = synth_slice("smooth:64:16")
        do_load(link, entries, imps, vec_len)
        thr = quantile_threshold(imps, 0.5)
        st = g.unpack_stats(link.transact(g.CMD_RUN, bytes([0, thr])))
        st2 = g.unpack_stats(link.transact(g.CMD_GET_STATS))
        assert st == st2, "RUN and GET_STATS records differ"
        stream = link.transact(g.CMD_GET_DATA)
        assert len(stream) == st["comp_bytes"], "GET_DATA length != comp_bytes"
        g.verify_roundtrip(entries, imps, thr, stream)
        restored = link.transact(g.CMD_GET_RESTORED)
        assert restored == g.restored_stream(entries, imps, thr), \
            "GET_RESTORED != bitmap + kept originals"

        # 3. SOF hunting: garbage bytes queued before the next response
        shim.txbuf += bytes([0x00, 0xA5, 0x13, 0xFE])
        pay = link.transact(g.CMD_PING)
        assert pay[:2] == bytes([g.VERSION[0], g.VERSION[1]]), "SOF hunt failed"

        # 4. corrupted host frame -> device NAKs with ERR_CKSUM
        bad = bytearray(g.build_frame(g.CMD_PING))
        bad[-1] ^= 0xFF
        shim.write(bytes(bad))
        rcmd, rpay = link.read_response()
        assert rcmd == 0xFF and rpay == bytes([g.ERR_CKSUM]), \
            f"expected ERR_CKSUM NAK, got cmd 0x{rcmd:02X} payload {rpay.hex()}"

        # 5. unknown command -> NAK -> single retry -> loud failure
        try:
            link.transact(0x7E)
            raise AssertionError("unknown command did not raise after retry")
        except LinkError:
            pass
    except AssertionError as e:
        print(f"FAIL: kv_host selftest: {e}")
        return 1
    print("PASS: kv_host selftest")
    return 0


# ------------------------------------------------------------------ CLI plumbing

def add_slice_args(sp):
    grp = sp.add_mutually_exclusive_group(required=True)
    grp.add_argument("--npz", help=".npz slice file from export_kv.py")
    grp.add_argument("--synthetic", metavar="FAMILY:N:LEN",
                     help="generated slice, e.g. smooth:256:64 "
                          "(families: constant/ramp/random/smooth)")


def main(argv=None):
    # Link options are accepted both before and after the subcommand
    # ("kv_host.py --port COM4 ping" and "kv_host.py ping --port COM4").
    # The subcommand copy uses SUPPRESS defaults so it only writes into the
    # namespace when actually supplied (otherwise it would clobber values
    # parsed before the subcommand with its defaults).
    def link_parent(suppress):
        d = argparse.SUPPRESS if suppress else None
        p = argparse.ArgumentParser(add_help=False)
        p.add_argument("--port", default=d if suppress else None,
                       help="serial port (required for hardware commands)")
        p.add_argument("--baud", type=int, default=d if suppress else 921600)
        p.add_argument("--timeout", type=float, default=d if suppress else 1.0)
        return p

    link_sub = link_parent(True)

    ap = argparse.ArgumentParser(
        description="Host CLI for the Basys 3 KV-cache optimizer",
        parents=[link_parent(False)])
    sub = ap.add_subparsers(dest="command", required=True)

    sub.add_parser("ping", parents=[link_sub],
                   help="PING the device, print version/max_entries")

    sp = sub.add_parser("check", parents=[link_sub],
                        help="load a slice, run, verify bit-exact")
    add_slice_args(sp)
    thr = sp.add_mutually_exclusive_group()
    thr.add_argument("--threshold", type=int, default=0,
                     help="eviction threshold 0..255 (default 0 = keep all)")
    thr.add_argument("--quantile", type=float, default=None,
                     help="derive threshold as this quantile of imps (0..1)")

    sp = sub.add_parser("restore", parents=[link_sub],
                        help="load, run, then verify fabric decompression (v1.1)")
    add_slice_args(sp)
    thr2 = sp.add_mutually_exclusive_group()
    thr2.add_argument("--threshold", type=int, default=0,
                      help="eviction threshold 0..255 (default 0 = keep all)")
    thr2.add_argument("--quantile", type=float, default=None,
                      help="derive threshold as this quantile of imps (0..1)")

    sp = sub.add_parser("sweep", parents=[link_sub],
                        help="run all thresholds, write CSV")
    add_slice_args(sp)
    sp.add_argument("--out", default="sweep.csv")
    sp.add_argument("--points", type=int, default=256,
                    help="number of thresholds (default 256 = all)")

    sub.add_parser("selftest", help="validate CLI framing against golden model")

    args = ap.parse_args(argv)

    if args.command == "selftest":
        return cmd_selftest(args)

    if not args.port:
        ap.error(f"--port is required for the '{args.command}' command")
    link = SerialLink.open(args.port, args.baud, args.timeout)
    try:
        handler = {"ping": cmd_ping, "check": cmd_check, "sweep": cmd_sweep,
                   "restore": cmd_restore}
        return handler[args.command](link, args)
    except LinkError as e:
        print(f"FAIL: {e}")
        return 1
    finally:
        link.close()


if __name__ == "__main__":
    sys.exit(main())
