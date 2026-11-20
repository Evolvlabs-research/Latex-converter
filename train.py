"""Entraînement : uv run train.py [--limit 64 --epochs 300 pour vérifier que le modèle apprend]."""
import argparse
import json
import time
from pathlib import Path

import torch
from torch.utils.data import DataLoader

from data import PAD, MathWriting, Vocab, collate, load_index
from model import Im2Latex


def exact_match(model, loader, device, max_batches: int) -> float:
    """Part des formules reconnues sans aucune erreur de token (la mesure standard du domaine)."""
    model.eval()
    ok = n = 0
    for b, (x, widths, y) in enumerate(loader):
        if b == max_batches:
            break
        # au-delà de la longueur de la vraie formule, la prédiction est fausse : inutile de décoder plus loin
        for pred, gold in zip(model.greedy(x.to(device), widths, max_len=y.shape[1] + 1), y[:, 1:].tolist()):
            ok += pred == [t for t in gold if t != PAD][:-1]  # gold sans EOS ni PAD
            n += 1
    model.train()
    return ok / max(n, 1)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--data", type=Path, default=Path("data/mathwriting-2024"))
    p.add_argument("--out", type=Path, default=Path("checkpoints"))
    p.add_argument("--epochs", type=int, default=20)
    p.add_argument("--batch", type=int, default=64)
    p.add_argument("--lr", type=float, default=3e-4)
    p.add_argument("--limit", type=int, help="n'utiliser que N exemples (test de surapprentissage)")
    p.add_argument("--workers", type=int, default=8)
    args = p.parse_args()

    device = "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu"
    # shortcut: seul le split « train » (humain) sert ; ajouter « synthetic » quand le modèle plafonne.
    vocab = Vocab([t for _, toks in load_index(args.data, "train") for t in toks])
    overfit = args.limit is not None
    train = MathWriting(args.data, "train", vocab, augment=not overfit, limit=args.limit)
    # en test de surapprentissage, on évalue sur les mêmes exemples
    val = train if overfit else MathWriting(args.data, "valid", vocab)
    tl = DataLoader(train, args.batch, shuffle=True, collate_fn=collate, num_workers=args.workers,
                    persistent_workers=args.workers > 0)
    vl = DataLoader(val, args.batch, collate_fn=collate, num_workers=args.workers)

    model = Im2Latex(len(vocab)).to(device)
    print(f"{sum(p.numel() for p in model.parameters()) / 1e6:.1f} M paramètres, {len(vocab)} tokens, "
          f"{len(train)} exemples, appareil {device}")
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, args.lr, total_steps=args.epochs * len(tl), pct_start=0.05)
    loss_fn = torch.nn.CrossEntropyLoss(ignore_index=PAD, label_smoothing=0.0 if overfit else 0.1)

    args.out.mkdir(exist_ok=True)
    best = -1.0
    for epoch in range(1, args.epochs + 1):
        t0, total = time.time(), 0.0
        for x, widths, y in tl:
            x, y = x.to(device), y.to(device)
            logits = model(x, widths, y[:, :-1])
            loss = loss_fn(logits.reshape(-1, logits.shape[-1]), y[:, 1:].reshape(-1))
            opt.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            sched.step()
            total += loss.item()
        em = exact_match(model, vl, device, max_batches=len(vl) if overfit else 30)
        print(f"époque {epoch} : perte {total / len(tl):.3f}, formules exactes {em:.1%}, {time.time() - t0:.0f} s",
              flush=True)
        if em > best:
            best = em
            torch.save({"model": model.state_dict(), "vocab": vocab.itos}, args.out / "best.pt")
    (args.out / "vocab.json").write_text(json.dumps(vocab.itos))


if __name__ == "__main__":
    main()
