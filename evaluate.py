"""Statistiques finales sur le jeu de test : uv run evaluate.py [--ckpt checkpoints/best.pt]

Écrit aussi le résultat dans <dossier du checkpoint>/test_stats.json.
"""
import argparse
import json
import time
from pathlib import Path

import torch
from torch.utils.data import DataLoader

from data import PAD, MathWriting, Vocab, WidthBatches, collate, detokenize
from model import Im2Latex

BUCKETS = [(1, 10), (11, 25), (26, 50), (51, 10_000)]  # longueur de la formule, en tokens


def edit_distance(a: list, b: list) -> int:
    """Nombre minimal d'insertions, suppressions et remplacements de tokens (Levenshtein)."""
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--data", type=Path, default=Path("data/mathwriting-2024"))
    p.add_argument("--ckpt", type=Path, default=Path("checkpoints/best.pt"))
    p.add_argument("--split", default="test")
    p.add_argument("--limit", type=int)
    args = p.parse_args()

    device = "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu"
    ckpt = torch.load(args.ckpt, map_location="cpu")
    vocab = Vocab([])
    vocab.itos, vocab.stoi = ckpt["vocab"], {t: i for i, t in enumerate(ckpt["vocab"])}
    model = Im2Latex(len(vocab)).to(device)
    model.load_state_dict(ckpt["model"])
    model.eval()
    ds = MathWriting(args.data, args.split, vocab, limit=args.limit)
    dl = DataLoader(ds, batch_sampler=WidthBatches(ds.widths, 64, seed=0), collate_fn=collate)

    dists, lengths, examples = [], [], []
    t0 = time.time()
    for x, widths, y in dl:
        # gold + 2 tokens suffisent pour compter jusqu'à 2 erreurs
        preds = model.greedy(x.to(device), widths, max_len=y.shape[1] + 1)
        for pred, gold in zip(preds, y[:, 1:].tolist()):
            gold = [t for t in gold if t != PAD][:-1]  # sans EOS ni PAD
            d = edit_distance(pred, gold)
            dists.append(d)
            lengths.append(len(gold))
            if d and len(examples) < 15:
                examples.append({"attendu": detokenize(vocab.decode(gold)), "prédit": detokenize(vocab.decode(pred))})
    seconds = time.time() - t0

    n = len(dists)
    stats = {
        "split": args.split,
        "formules": n,
        "exactes": sum(d == 0 for d in dists) / n,
        "≤1 erreur": sum(d <= 1 for d in dists) / n,
        "≤2 erreurs": sum(d <= 2 for d in dists) / n,
        "taux d'erreur par token": sum(dists) / max(sum(lengths), 1),
        "ms par formule": 1000 * seconds / n,
        "par longueur": {
            f"{lo}-{hi if hi < 10_000 else '+'}": {
                "formules": len(sel := [d for d, L in zip(dists, lengths) if lo <= L <= hi]),
                "exactes": sum(d == 0 for d in sel) / max(len(sel), 1),
            }
            for lo, hi in BUCKETS
        },
        "exemples d'erreurs": examples,
    }
    out = args.ckpt.parent / f"{args.split}_stats.json"
    out.write_text(json.dumps(stats, ensure_ascii=False, indent=2))
    print(json.dumps({k: v for k, v in stats.items() if k != "exemples d'erreurs"}, ensure_ascii=False, indent=2))
    print(f"Détail et exemples d'erreurs : {out}")


if __name__ == "__main__":
    main()
