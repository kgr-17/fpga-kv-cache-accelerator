"""Offline dry-run of the hardware sweep: run the golden eviction+compression
pipeline over an exported .npz slice across thresholds, verifying bit-exactness.

Usage: python golden_sweep.py slices.npz [thr thr ...]
"""
import sys

import numpy as np

import golden as g


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "slices_l2h5k.npz"
    thrs = [int(t) for t in sys.argv[2:]] or [0, 1, 2, 3, 5, 10, 50, 128]
    d = np.load(path, allow_pickle=True)
    vals, imps = d["values"], d["imps"]
    entries = [bytes(vals[i].tolist()) for i in range(vals.shape[0])]
    il = imps.tolist()
    print(f"slice: {len(entries)} entries x {len(entries[0])} B, "
          f"scale {float(d['scale']):.6f}, meta {d['meta']}")
    print(f"{'thr':>4} {'kept':>5} {'comp_B':>7} {'eff_ratio':>9} {'bypass%':>8}  bit-exact")
    for thr in thrs:
        stream, st = g.encode_stream(entries, il, thr)
        ok = g.verify_roundtrip(entries, il, thr, stream)
        kept = st["entries_kept"]
        print(f"{thr:>4} {kept:>5} {st['comp_bytes']:>7} "
              f"{st['orig_bytes'] / st['comp_bytes']:>9.2f} "
              f"{100 * st['bypass_cnt'] / max(kept, 1):>7.1f}%  {ok}")


if __name__ == "__main__":
    main()
