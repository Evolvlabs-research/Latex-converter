"""Tests rapides, sans données : uv run test_hmer.py"""
import tempfile
from pathlib import Path

import torch

from data import (EOS, HEIGHT, MAX_WIDTH, MathWriting, Vocab, WidthBatches, collate, detokenize, read_inkml,
                  render, to_tensor, tokenize)
from model import Im2Latex

# tokenizer
toks = tokenize(r"\frac{a}{b}+\alpha x\{")
assert toks == ["\\frac", "{", "a", "}", "{", "b", "}", "+", "\\alpha", "x", "\\{"], toks
assert detokenize(toks) == r"\frac{a}{b}+\alpha x\{"
v = Vocab(toks)
assert v.decode(v.encode(toks)) == toks

# rendu : hauteur fixe, largeur bornée, signe plat non déformé
for strokes in ([[(0, 0), (10, 10)], [(10, 0), (0, 10)]], [[(0, 0), (1000, 1)]], [[(5, 5)]]):
    img = render(strokes, augment=True)
    assert img.height == HEIGHT and 32 <= img.width <= MAX_WIDTH and img.getbbox(), strokes

# modèle : formes, masque de remplissage, décodage glouton
batch = [(to_tensor(render([[(0, 0), (w, 10)]])), torch.tensor(v.encode(toks))) for w in (10, 200)]
x, widths, y = collate(batch)
m = Im2Latex(len(v)).eval()
assert m(x, widths, y[:, :-1]).shape == (2, y.shape[1] - 1, len(v))
out = m.greedy(x, widths, max_len=8)
assert len(out) == 2 and all(len(o) <= 7 and EOS not in o for o in out)
# collate : tailles arrondies (largeur à 128 px, longueur à 16 tokens)
assert x.shape[-1] % 128 == 0 and y.shape[1] % 16 == 0 and widths.tolist() == [b[0].shape[-1] for b in batch]

# lots par largeur : chaque exemple une seule fois, largeurs proches dans un lot
ws = torch.randint(32, 1024, (1000,)).tolist()
lots = list(WidthBatches(ws, 10))
assert sorted(i for lot in lots for i in lot) == list(range(1000)) and len(lots) == len(WidthBatches(ws, 10))
assert sum(max(ws[i] for i in l) - min(ws[i] for i in l) for l in lots) / len(lots) < 100
assert list(WidthBatches(ws, 10, seed=0)) == list(WidthBatches(ws, 10, seed=0))

# cache binaire : mêmes traits (à la précision float16 près) que l'InkML
root = Path(tempfile.mkdtemp())
(root / "train").mkdir()
traces = [[(10, 20), (30, 60), (50, 20)], [(70, 40)], [(80, 20), (120, 60)]]
ink = "".join(f"<trace>{', '.join(f'{a} {b} 0' for a, b in t)}</trace>" for t in traces)
(root / "train" / "a.inkml").write_text(
    f'<ink xmlns="http://www.w3.org/2003/InkML"><annotation type="normalizedLabel">x^{{2}}</annotation>{ink}</ink>')
ds = MathWriting(root, "train", Vocab(tokenize("x^{2}")))
img, seq = ds[0]
ref = to_tensor(render(read_inkml(root / "train" / "a.inkml")[0]))
assert len(ds) == 1 and seq.tolist() == ds.seqs[0]
assert img.shape == ref.shape and (img - ref).abs().mean() < 0.01
assert ds.widths[0] == img.shape[-1]
print("OK")
