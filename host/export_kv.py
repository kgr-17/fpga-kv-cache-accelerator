#!/usr/bin/env python3
"""Export a real distilgpt2 KV-cache slice to .npz for the Basys 3 optimizer.

Runs one forward pass with the KV cache and attention weights enabled, takes
layer L / head H of the K or V cache -> a (T, 64) float slice, quantizes it
with golden.quantize (per-slice symmetric int8, one scale), and derives a
per-token importance score H2O-style: total attention RECEIVED by each token
(column-sum of the T x T attention matrix), min-max normalized to 0..255,
with the last 16 tokens forced to 255 (recency window).

Output npz keys: values (uint8 [T,64]), imps (uint8 [T]), scale (float),
meta (str). Consumed by kv_host.py and plots.py. Python 3.9 compatible.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import golden as g

RECENCY_WINDOW = 16

# ~300-word default input so a fresh checkout produces a nontrivial slice.
DEFAULT_TEXT = """
The key-value cache is the quiet workhorse of transformer inference. Every time
a language model generates a token, it attends over the keys and values of all
previous tokens, and recomputing those tensors from scratch at each step would
be ruinously slow. So the model stores them: one key vector and one value
vector per token, per head, per layer. The arithmetic is small but the memory
is not. A modest model with a few thousand tokens of context already carries
megabytes of cached state, and serving systems that batch many long
conversations together find that the cache, not the weights, dominates their
memory budget. This has made cache compression a lively research area. Two
observations do most of the work. First, attention is sparse in practice: a
small subset of tokens receives the overwhelming majority of attention mass,
while many tokens are barely looked at again after they are written. Scoring
each token by the attention it has accumulated, and evicting the low scorers,
preserves quality surprisingly well, provided the most recent tokens are always
kept because the model reads them constantly. Second, the cached vectors
themselves are smooth and highly redundant, so cheap tricks like quantization
to eight bits, delta encoding between neighboring values, and run-length coding
of the resulting zeros can shrink what remains without touching the model at
all. The combination of eviction and lightweight compression composes
multiplicatively, which is why even a toy hardware accelerator can demonstrate
a meaningful reduction. The experiment here is deliberately small: one head of
one layer of a distilled GPT-2, a few hundred tokens, an importance score per
token, and a byte-exact pipeline that a student FPGA board can execute in
microseconds. The point is not scale but fidelity: the bytes that come back
from the board must match the reference model exactly, bit for bit.
""".strip()


def load_text(args):
    if args.text is not None:
        return args.text
    if args.file is not None:
        with open(args.file, "r", encoding="utf-8") as f:
            return f.read()
    return DEFAULT_TEXT


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Export a distilgpt2 KV slice + importance scores to .npz")
    ap.add_argument("--model", default="distilgpt2")
    ap.add_argument("--layer", type=int, default=0)
    ap.add_argument("--head", type=int, default=0)
    ap.add_argument("--kv", choices=["k", "v"], default="k",
                    help="export keys or values (default k)")
    ap.add_argument("--max-tokens", type=int, default=512, dest="max_tokens")
    ap.add_argument("--out", default="slices.npz")
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--text", help="inline input text")
    src.add_argument("--file", help="read input text from this file")
    args = ap.parse_args(argv)

    import numpy as np
    import torch
    from transformers import AutoTokenizer, GPT2LMHeadModel

    text = load_text(args)

    tok = AutoTokenizer.from_pretrained(args.model)
    try:
        # eager attention keeps output_attentions available on new transformers
        model = GPT2LMHeadModel.from_pretrained(args.model,
                                                attn_implementation="eager")
    except TypeError:
        model = GPT2LMHeadModel.from_pretrained(args.model)
    model.eval()

    n_layer = model.config.n_layer
    n_head = model.config.n_head
    if not (0 <= args.layer < n_layer):
        raise SystemExit(f"--layer {args.layer} out of range 0..{n_layer - 1}")
    if not (0 <= args.head < n_head):
        raise SystemExit(f"--head {args.head} out of range 0..{n_head - 1}")

    ids = tok(text, return_tensors="pt").input_ids
    if ids.shape[1] > args.max_tokens:
        ids = ids[:, -args.max_tokens:]         # keep the most recent tokens
    n_pos = getattr(model.config, "n_positions", 1024)
    if ids.shape[1] > n_pos:
        ids = ids[:, -n_pos:]
    if ids.shape[1] < 1:
        raise SystemExit("input text tokenized to zero tokens")

    with torch.no_grad():
        out = model(ids, use_cache=True, output_attentions=True)

    pkv = out.past_key_values
    if hasattr(pkv, "to_legacy_cache"):         # transformers >= 4.36 Cache object
        pkv = pkv.to_legacy_cache()
    k, v = pkv[args.layer][0], pkv[args.layer][1]   # each (1, heads, T, head_dim)
    tens = k if args.kv == "k" else v
    slice_f = tens[0, args.head].float()            # (T, head_dim)
    T, head_dim = slice_f.shape
    if head_dim > g.VEC_MAX:
        raise SystemExit(f"head_dim {head_dim} exceeds device VEC_MAX {g.VEC_MAX}")

    # H2O-style importance: attention received by key position j, summed over
    # all query positions i of the (T, T) attention matrix.
    att = out.attentions[args.layer][0, args.head].float()      # (T, T)
    imp_f = att.sum(dim=0).numpy()                              # (T,)
    lo, hi = float(imp_f.min()), float(imp_f.max())
    if hi > lo:
        imps = np.round((imp_f - lo) / (hi - lo) * 255.0).astype(np.uint8)
    else:
        imps = np.full(T, 128, dtype=np.uint8)  # degenerate: no preference

    # Device holds at most MAX_ENTRIES entries: keep the most recent tokens.
    if T > g.MAX_ENTRIES:
        slice_f = slice_f[-g.MAX_ENTRIES:]
        imps = imps[-g.MAX_ENTRIES:]
        T = g.MAX_ENTRIES

    imps[-RECENCY_WINDOW:] = 255                # recency window: never evict

    # Per-slice symmetric quantization via the golden model (one scale).
    qbytes, scale = g.quantize(slice_f.flatten().tolist())
    values = np.frombuffer(qbytes, dtype=np.uint8).reshape(T, head_dim).copy()

    meta = (f"model={args.model} layer={args.layer} head={args.head} "
            f"kv={args.kv} T={T}")
    np.savez(args.out, values=values, imps=imps,
             scale=np.float64(scale), meta=meta)

    q0, q1, q2, q3, q4 = np.percentile(imps, [0, 25, 50, 75, 100])
    print(f"wrote {args.out}")
    print(f"  meta : {meta}")
    print(f"  T    : {T} tokens, vec_len {head_dim}")
    print(f"  scale: {scale:.6g}")
    print(f"  imps : min {q0:.0f} / q25 {q1:.0f} / median {q2:.0f} / "
          f"q75 {q3:.0f} / max {q4:.0f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
