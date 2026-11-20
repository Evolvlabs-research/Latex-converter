"""Tests rapides, sans données : uv run test_hmer.py"""
import torch

from data import EOS, HEIGHT, MAX_WIDTH, Vocab, collate, detokenize, render, to_tensor, tokenize
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
print("OK")
