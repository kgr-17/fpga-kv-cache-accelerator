"""Perplexity ablation: what does KV-cache eviction cost the model?

Prefills distilgpt2 on a context, scores every context token with the same
H2O-style accumulated-attention importance the hardware uses, prunes the
KV-cache to a range of kept fractions under three policies, and measures
teacher-forced perplexity on a held-out continuation span.

Policies:
  h2o      keep top-score tokens + the last RECENCY tokens (what the FPGA does)
  recency  keep only the last k tokens (StreamingLLM-style baseline)
  random   keep k uniformly random tokens incl. recency window (control)

Output: ppl.csv (policy, kept_fraction, kept_tokens, ppl) and
docs/reports/ppl.png. Pure host-side: no RTL involved; this measures the
POLICY the hardware implements, at model scale it cannot hold.

Usage: python ppl_ablation.py [--model distilgpt2] [--ctx 402] [--eval 220]
                              [--file text.txt] [--out ppl.csv]
"""
import argparse
import csv
import math
import os
import random

import torch
from transformers import GPT2LMHeadModel, GPT2TokenizerFast

RECENCY = 16
FRACTIONS = [1.0, 0.75, 0.5, 0.3, 0.2, 0.1, 0.05]

# Neutral encyclopedic text, long enough for a 402-token context plus a
# 200+ token evaluation span. Any coherent English works for this experiment.
BUILTIN_TEXT = """
A river delta forms where a river meets a standing body of water and slows,
dropping the sediment it has carried downstream. Over centuries the deposits
build outward, splitting the main channel into a branching network of
distributaries. The shape a delta takes depends on the balance of three
forces: the river's own discharge, the energy of waves along the coast, and
the rise and fall of tides. Where the river dominates, the delta pushes long
fingers of land into the sea. Where waves dominate, the shoreline is smoothed
into gentle arcs. Where tides dominate, the mouth is combed into parallel
ridges and channels that fill and drain twice a day.

Deltas are among the most productive landscapes on Earth. Their soils are
renewed by flooding, their wetlands shelter fish nurseries and migratory
birds, and their flat, fertile plains have anchored agriculture since the
first cities. The same qualities make them crowded: hundreds of millions of
people live on deltas today, many in megacities that continue to grow. This
concentration creates a slow-moving emergency, because deltas are sinking.
Sediment that once replenished the surface is now trapped behind upstream
dams, groundwater pumping compacts the ground beneath the cities, and the
sea into which the deltas were built is rising.

Engineers respond with an old toolkit and a new one. The old toolkit is
resistance: levees, seawalls, pumps, and barriers that hold a line against
the water. The new toolkit is accommodation: diverting sediment-rich river
water into starved wetlands, setting back defenses to give floods room,
raising buildings instead of walls, and restoring the marshes and mangroves
that blunt storm surge naturally. Most large delta plans now mix both,
because neither alone has proven sufficient. The choice of mixture is as
much political as technical: resistance protects existing property lines,
while accommodation redraws them.

What makes deltas scientifically interesting is that they record their own
history. Each layer of sediment preserves the flood that laid it down, and
cores drilled through a delta read like a diary of the river's moods over
thousands of years. From these records, researchers can separate the natural
rhythm of growth and retreat from the acceleration that began when people
started farming the floodplains, damming the headwaters, and drawing water
from beneath the surface. The verdict of the cores is consistent across
continents: deltas that grew for six thousand years began, within a single
human lifetime, to shrink. Whether they can be turned around is one of the
defining engineering questions of the century, and the answer will be
written not in a single heroic project but in decades of sediment budgets,
setback lines, and maintenance schedules faithfully kept.
""".strip()


def importance_scores(attentions, ctx_len):
    """Global H2O score per context position: attention received, summed over
    layers, heads, and query positions — the model-wide version of the
    per-head score the hardware slices use."""
    score = torch.zeros(ctx_len, dtype=torch.float64)
    for layer_attn in attentions:                    # (1, H, C, C)
        score += layer_attn[0].sum(dim=(0, 1)).to(torch.float64)
    return score


def kept_indices(policy, score, ctx_len, k, rng):
    recent = list(range(max(0, ctx_len - RECENCY), ctx_len))
    if k >= ctx_len:
        return list(range(ctx_len))
    if policy == "recency":
        return list(range(ctx_len - k, ctx_len))
    if policy == "random":
        pool = [i for i in range(ctx_len) if i < ctx_len - RECENCY]
        extra = max(0, k - len(recent))
        return sorted(rng.sample(pool, extra) + recent)[:k] if extra else recent[-k:]
    # h2o: recency window always kept, remainder by score
    s = score.clone()
    s[recent] = float("inf")
    top = torch.topk(s, k).indices.tolist()
    return sorted(top)


def prune_past(past, idx):
    idx_t = torch.tensor(idx, dtype=torch.long)
    legacy = tuple((k.index_select(2, idx_t), v.index_select(2, idx_t))
                   for k, v in past)
    try:
        from transformers.cache_utils import DynamicCache
        return DynamicCache.from_legacy_cache(legacy)
    except Exception:
        return legacy


def scored_ppl(model, eval_ids, past, ctx_len):
    """Teacher-forced NLL of eval span given (possibly pruned) cache."""
    position_ids = torch.arange(ctx_len, ctx_len + eval_ids.shape[1]).unsqueeze(0)
    with torch.no_grad():
        out = model(input_ids=eval_ids, past_key_values=past,
                    position_ids=position_ids, use_cache=False)
    logits = out.logits[0, :-1]                       # predicts eval_ids[1:]
    targets = eval_ids[0, 1:]
    nll = torch.nn.functional.cross_entropy(logits, targets, reduction="mean")
    return math.exp(nll.item())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="distilgpt2")
    ap.add_argument("--ctx", type=int, default=402)
    ap.add_argument("--eval", type=int, default=220)
    ap.add_argument("--file", help="text file (default: built-in essay)")
    ap.add_argument("--out", default="ppl.csv")
    ap.add_argument("--plot", default=os.path.join("docs", "reports", "ppl.png"))
    args = ap.parse_args()

    text = open(args.file, encoding="utf-8").read() if args.file else BUILTIN_TEXT
    tok = GPT2TokenizerFast.from_pretrained(args.model)
    model = GPT2LMHeadModel.from_pretrained(args.model, attn_implementation="eager")
    model.eval()

    ids = tok(text, return_tensors="pt").input_ids
    need = args.ctx + args.eval
    if ids.shape[1] < need:
        raise SystemExit(f"text too short: {ids.shape[1]} tokens, need {need}")
    ctx_ids = ids[:, :args.ctx]
    eval_ids = ids[:, args.ctx:need]

    with torch.no_grad():
        pre = model(input_ids=ctx_ids, use_cache=True, output_attentions=True)
    score = importance_scores(pre.attentions, args.ctx)
    legacy_past = tuple((k, v) for k, v in pre.past_key_values)

    rng = random.Random(2026)
    rows = []
    for policy in ("h2o", "recency", "random"):
        for f in FRACTIONS:
            k = max(RECENCY, round(f * args.ctx))
            idx = kept_indices(policy, score, args.ctx, k, rng)
            ppl = scored_ppl(model, eval_ids, prune_past(legacy_past, idx),
                             args.ctx)
            rows.append({"policy": policy, "kept_fraction": round(f, 4),
                         "kept_tokens": len(idx), "ppl": round(ppl, 4)})
            print(f"{policy:8s} keep {len(idx):3d}/{args.ctx} "
                  f"({f:5.0%})  ppl {ppl:8.3f}")

    with open(args.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {args.out}")

    # plot
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(7, 4.2))
    styles = {"h2o": ("tab:orange", "o-", "H2O importance + recency (hardware policy)"),
              "recency": ("tab:blue", "s--", "recency only (StreamingLLM-style)"),
              "random": ("tab:gray", "^:", "random keep (control)")}
    for pol, (color, fmt, label) in styles.items():
        pts = sorted([r for r in rows if r["policy"] == pol],
                     key=lambda r: r["kept_fraction"])
        ax.plot([r["kept_fraction"] for r in pts], [r["ppl"] for r in pts],
                fmt, color=color, label=label, ms=5)
    full = next(r["ppl"] for r in rows
                if r["policy"] == "h2o" and r["kept_fraction"] == 1.0)
    ax.axhline(full, color="tab:green", lw=1, alpha=0.6)
    ax.annotate(f"full cache: {full:.1f}", xy=(0.02, full),
                fontsize=8, color="tab:green", va="bottom")
    ax.set_xlabel("fraction of context tokens kept")
    ax.set_ylabel(f"perplexity of {args.eval}-token continuation")
    ax.set_title(f"{args.model}: generation quality vs KV-cache eviction "
                 f"(ctx {args.ctx})")
    ax.grid(True, alpha=0.3)
    ax.legend(fontsize=8)
    fig.tight_layout()
    os.makedirs(os.path.dirname(args.plot), exist_ok=True)
    fig.savefig(args.plot, dpi=150)
    print(f"wrote {args.plot}")


if __name__ == "__main__":
    main()
