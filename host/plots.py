#!/usr/bin/env python3
"""Matplotlib figures for the Basys 3 KV-cache optimizer. Each subcommand
saves one .png:

  sweep      --csv sweep.csv  --out sweep.png       ratio + entries_kept vs threshold
  tradeoff   --npz slices.npz --out tradeoff.png    kept fraction vs reconstruction MSE
  throughput --csv sweep.csv  --out throughput.png  engine vs UART link bytes/s

The sweep CSV comes from `kv_host.py sweep`. Python 3.9 compatible.
"""
import argparse
import csv
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import golden as g

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

F_CLK = 100e6           # engine clock, cycles -> seconds
MSE_FLOOR = 1e-12       # display floor so exact-zero MSE is visible on log axis


def read_sweep_csv(path):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            rows.append({
                "threshold": int(r["threshold"]),
                "entries_kept": int(r["entries_kept"]),
                "orig_bytes": int(r["orig_bytes"]),
                "comp_bytes": int(r["comp_bytes"]),
                "ratio": float(r["ratio"]),
                "bypass_cnt": int(r["bypass_cnt"]),
                "cycles": int(r["cycles"]),
            })
    if not rows:
        raise SystemExit(f"{path}: no data rows")
    rows.sort(key=lambda r: r["threshold"])
    return rows


def dequant_matrix(values_u8, scale):
    """uint8 two's-complement matrix -> float matrix (golden.dequantize, vectorized)."""
    s = values_u8.astype(np.int16)
    s[s >= 128] -= 256
    return s.astype(np.float64) * scale


# ------------------------------------------------------------------ subcommands

def cmd_sweep(args):
    rows = read_sweep_csv(args.csv)
    if args.xmax is not None:
        rows = [r for r in rows if r["threshold"] <= args.xmax]
    thr = [r["threshold"] for r in rows]
    ratio = [r["ratio"] for r in rows]
    kept = [r["entries_kept"] for r in rows]

    fig, ax1 = plt.subplots(figsize=(8, 4.5))
    l1, = ax1.plot(thr, ratio, color="tab:blue", lw=1.8,
                   label="effective ratio (orig/comp)")
    ax1.set_xlabel("eviction threshold")
    ax1.set_ylabel("effective ratio (orig_bytes / comp_bytes)", color="tab:blue")
    ax1.tick_params(axis="y", labelcolor="tab:blue")
    ax1.grid(True, alpha=0.3)

    ax2 = ax1.twinx()
    l2, = ax2.plot(thr, kept, color="tab:orange", lw=1.8, label="entries kept")
    ax2.set_ylabel("entries kept", color="tab:orange")
    ax2.tick_params(axis="y", labelcolor="tab:orange")

    ax1.legend(handles=[l1, l2], loc="upper left")
    ax1.set_title("Threshold sweep: compression ratio and retention")
    fig.tight_layout()
    fig.savefig(args.out, dpi=150)
    print(f"wrote {args.out} ({len(rows)} sweep points)")
    return 0


def cmd_tradeoff(args):
    d = np.load(args.npz)
    values = np.asarray(d["values"], dtype=np.uint8)
    imps = [int(x) for x in np.asarray(d["imps"], dtype=np.uint8).tolist()]
    scale = float(d["scale"])
    n, vec_len = values.shape
    entries = [values[i].tobytes() for i in range(n)]
    orig_f = dequant_matrix(values, scale)

    # thresholds covering the whole importance range (plus an evict-all point)
    thresholds = sorted(set(imps) | {0, min(255, max(imps) + 1)})

    kept_frac, mse_all, mse_kept = [], [], []
    for t in thresholds:
        # honest end-to-end path: golden encode -> decode -> dequantize
        stream, stats = g.encode_stream(entries, imps, t)
        decoded = g.decode_stream(stream, n, vec_len)
        recon = np.zeros_like(orig_f)           # evicted vectors count as zeros
        for i, vals in decoded.items():
            recon[i] = dequant_matrix(
                np.frombuffer(vals, dtype=np.uint8).reshape(1, vec_len), scale)
        err2 = (recon - orig_f) ** 2
        kept_frac.append(stats["entries_kept"] / n)
        mse_all.append(float(err2.mean()))
        if decoded:
            kept_idx = sorted(decoded.keys())
            mse_kept.append(float(err2[kept_idx].mean()))
        else:
            mse_kept.append(float("nan"))       # no kept positions to average

    order = np.argsort(kept_frac)
    kf = np.array(kept_frac)[order]
    m_all = np.maximum(np.array(mse_all)[order], MSE_FLOOR)
    m_kept = np.maximum(np.array(mse_kept)[order], MSE_FLOOR)

    fig, ax = plt.subplots(figsize=(8, 4.5))
    ax.semilogy(kf, m_all, "o-", ms=3, color="tab:red",
                label="MSE over ALL positions (evicted counted as zeros)")
    ax.semilogy(kf, m_kept, "s--", ms=3, color="tab:green",
                label=f"MSE over kept positions only "
                      f"(lossless: 0, shown at {MSE_FLOOR:g} floor)")
    ax.set_xlabel("kept fraction (entries_kept / entries_in)")
    ax.set_ylabel("MSE of dequantized reconstruction (log)")
    ax.set_title(f"Eviction trade-off ({n} entries x {vec_len}, "
                 f"scale {scale:.4g})")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(loc="best", fontsize=8)
    fig.tight_layout()
    fig.savefig(args.out, dpi=150)
    print(f"wrote {args.out} ({len(thresholds)} threshold points)")
    return 0


def _fmt_rate(bps):
    if bps >= 1e6:
        return f"{bps / 1e6:.1f} MB/s"
    return f"{bps / 1e3:.1f} kB/s"


def cmd_throughput(args):
    rows = read_sweep_csv(args.csv)
    row0 = next((r for r in rows if r["threshold"] == 0), None)
    if row0 is None:
        raise SystemExit(f"{args.csv}: no threshold=0 row (needed as baseline)")
    if row0["cycles"] <= 0 or row0["entries_kept"] <= 0:
        raise SystemExit(f"{args.csv}: threshold=0 row has cycles=0 -- "
                         "the sweep must come from real hardware/RTL")
    # threshold 0 keeps everything, so vec_len = orig_bytes / entries_kept
    vec_len = row0["orig_bytes"] / row0["entries_kept"]

    engine_orig = row0["orig_bytes"] / row0["cycles"] * F_CLK
    # engine-honest throughput is roughly threshold-independent: take the
    # median of kept_bytes/cycles over all usable sweep rows
    kept_tps = [r["entries_kept"] * vec_len / r["cycles"] * F_CLK
                for r in rows if r["cycles"] > 0 and r["entries_kept"] > 0]
    engine_kept = float(np.median(kept_tps))
    uart = args.baud / 10.0                     # 8N1: 10 bit times per byte

    labels = ["engine\norig bytes (thr=0)",
              "engine\nkept bytes (median)",
              f"UART link\n({args.baud} baud / 10)"]
    vals = [engine_orig, engine_kept, uart]
    colors = ["tab:blue", "tab:cyan", "tab:gray"]

    fig, ax = plt.subplots(figsize=(7, 4.5))
    bars = ax.bar(labels, vals, color=colors)
    ax.set_yscale("log")
    ax.set_ylabel("throughput (bytes/s, log)")
    ax.set_title("Engine vs UART link throughput")
    ax.grid(True, axis="y", which="both", alpha=0.3)
    for b, v in zip(bars, vals):
        ax.annotate(_fmt_rate(v), (b.get_x() + b.get_width() / 2, v),
                    ha="center", va="bottom", fontsize=9)
    fig.tight_layout()
    fig.savefig(args.out, dpi=150)
    print(f"engine orig: {_fmt_rate(engine_orig)}, "
          f"engine kept: {_fmt_rate(engine_kept)}, uart: {_fmt_rate(uart)}")
    print(f"wrote {args.out}")
    return 0


# ------------------------------------------------------------------ CLI plumbing

def main(argv=None):
    ap = argparse.ArgumentParser(description="KV-cache optimizer figures")
    sub = ap.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("sweep", help="ratio + entries_kept vs threshold")
    sp.add_argument("--csv", default="sweep.csv")
    sp.add_argument("--out", default="sweep.png")
    sp.add_argument("--xmax", type=int, default=None,
                    help="clip x-axis (skewed importance packs the action "
                         "into low thresholds)")

    sp = sub.add_parser("tradeoff", help="kept fraction vs reconstruction MSE")
    sp.add_argument("--npz", required=True)
    sp.add_argument("--out", default="tradeoff.png")

    sp = sub.add_parser("throughput", help="engine vs UART throughput bars")
    sp.add_argument("--csv", default="sweep.csv")
    sp.add_argument("--baud", type=int, default=2000000)
    sp.add_argument("--out", default="throughput.png")

    args = ap.parse_args(argv)
    handler = {"sweep": cmd_sweep, "tradeoff": cmd_tradeoff,
               "throughput": cmd_throughput}
    return handler[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
