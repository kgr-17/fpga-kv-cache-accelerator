"""Layer x head evictability map, measured on the Artix-7 accelerator.

One distilgpt2 forward pass yields the K tensors and attention maps for all
6 layers x 12 heads. Each head's slice is quantized and importance-scored
exactly as export_kv.py does, then run through the eviction+compression
engine ON THE BOARD at thresholds 0..16. Falls back to the golden model
(clearly labeled) if no board is reachable.

Metrics per (layer, head):
  ratio3      effective compression ratio at threshold 3
  keptfrac3   fraction of tokens kept at threshold 3
  thr4x       smallest threshold reaching >= 4x (17 = never within 0..16)
  medimp      median importance byte (host-side, distribution shape)

Usage: python evict_map.py [--port COM4] [--ctx 402] [--out evict_map.csv]
"""
import argparse
import csv
import os

import numpy as np
import torch
from transformers import GPT2LMHeadModel, GPT2TokenizerFast

import golden as g
from ppl_ablation import BUILTIN_TEXT, RECENCY

THRESHOLDS = list(range(0, 17))


def extract_all(model_name, ctx_len):
    tok = GPT2TokenizerFast.from_pretrained(model_name)
    model = GPT2LMHeadModel.from_pretrained(model_name, attn_implementation="eager")
    model.eval()
    ids = tok(BUILTIN_TEXT, return_tensors="pt").input_ids[:, :ctx_len]
    with torch.no_grad():
        out = model(input_ids=ids, use_cache=True, output_attentions=True)
    n_layers = len(out.past_key_values)
    n_heads = out.past_key_values[0][0].shape[1]
    slices = {}
    for l in range(n_layers):
        k_tensor = out.past_key_values[l][0][0]          # (H, T, 64)
        attn = out.attentions[l][0]                      # (H, T, T)
        for h in range(n_heads):
            vals = k_tensor[h].numpy().astype(np.float64)   # (T, 64)
            qbytes, _ = g.quantize(vals.flatten().tolist())
            values = np.frombuffer(qbytes, dtype=np.uint8).reshape(vals.shape)
            score = attn[h].sum(dim=0).numpy()           # attention received
            lo, hi = score.min(), score.max()
            imps = ((score - lo) / (hi - lo) * 255.0 if hi > lo
                    else np.zeros_like(score))
            imps = imps.astype(np.uint8)
            imps[-RECENCY:] = 255                        # recency window
            slices[(l, h)] = (values, imps)
    return slices, n_layers, n_heads


def measure_hw(link, values, imps):
    from kv_host import do_load
    entries = [values[i].tobytes() for i in range(values.shape[0])]
    do_load(link, entries, [int(x) for x in imps], values.shape[1])
    out = {}
    for thr in THRESHOLDS:
        st = g.unpack_stats(link.transact(g.CMD_RUN, bytes([0, thr])))
        out[thr] = (st["orig_bytes"] / st["comp_bytes"] if st["comp_bytes"] else 0.0,
                    st["entries_kept"] / st["entries_in"])
    return out


def measure_golden(values, imps):
    entries = [values[i].tobytes() for i in range(values.shape[0])]
    out = {}
    for thr in THRESHOLDS:
        _, stats = g.encode_stream(entries, [int(x) for x in imps], thr)
        out[thr] = (stats["orig_bytes"] / stats["comp_bytes"],
                    stats["entries_kept"] / stats["entries_in"])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None, help="serial port (omit = golden model)")
    ap.add_argument("--baud", type=int, default=921600)
    ap.add_argument("--model", default="distilgpt2")
    ap.add_argument("--ctx", type=int, default=402)
    ap.add_argument("--out", default="evict_map.csv")
    ap.add_argument("--plot", default=os.path.join("docs", "reports", "evict_map.png"))
    args = ap.parse_args()

    link, source = None, "golden model (host)"
    if args.port:
        from kv_host import SerialLink
        link = SerialLink.open(args.port, args.baud, timeout=2.0)
        source = f"Artix-7 hardware ({args.port})"
    print(f"measurement source: {source}")

    slices, n_layers, n_heads = extract_all(args.model, args.ctx)
    rows = []
    ratio3 = np.zeros((n_layers, n_heads))
    for (l, h), (values, imps) in sorted(slices.items()):
        meas = measure_hw(link, values, imps) if link else measure_golden(values, imps)
        r3, kf3 = meas[3]
        thr4x = next((t for t in THRESHOLDS if meas[t][0] >= 4.0), 17)
        ratio3[l, h] = r3
        rows.append({"layer": l, "head": h, "ratio3": round(r3, 3),
                     "keptfrac3": round(kf3, 4), "thr4x": thr4x,
                     "medimp": int(np.median(imps))})
        print(f"L{l} H{h:2d}: ratio@3 {r3:6.2f}x  kept {kf3:5.1%}  "
              f"thr for 4x: {thr4x if thr4x < 17 else '>16'}")
    if link:
        link.close()

    with open(args.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {args.out}")

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(9, 4.6))
    im = ax.imshow(ratio3, cmap="YlOrBr", aspect="auto",
                   vmin=0, vmax=min(ratio3.max(), 25))
    for l in range(n_layers):
        for h in range(n_heads):
            v = ratio3[l, h]
            ax.text(h, l, f"{v:.1f}", ha="center", va="center", fontsize=8,
                    color="white" if v > 0.6 * min(ratio3.max(), 25) else "#333")
    ax.set_xticks(range(n_heads))
    ax.set_yticks(range(n_layers))
    ax.set_xlabel("attention head")
    ax.set_ylabel("layer")
    ax.set_title(f"Compression ratio at threshold 3 - {args.model} K tensors, "
                 f"ctx {args.ctx}\nmeasured on: {source}")
    fig.colorbar(im, ax=ax, label="effective ratio (x)")
    fig.tight_layout()
    os.makedirs(os.path.dirname(args.plot), exist_ok=True)
    fig.savefig(args.plot, dpi=150)
    print(f"wrote {args.plot}")


if __name__ == "__main__":
    main()
