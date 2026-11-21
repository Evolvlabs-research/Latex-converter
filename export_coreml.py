"""Exporte le modèle pour l'app Nabla : uv run export_coreml.py

Écrit dans app/Model/ : Encoder.mlpackage, Decoder.mlpackage (Core ML) et vocab.json.
Avec --reference N : lit aussi N InkML de validation avec Python, pour le test qui compare Swift et Python.
"""
import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from PIL import Image
from torch import nn

from data import HEIGHT, MAX_LEN, MAX_WIDTH, Vocab, detokenize, read_inkml, render, to_tensor
from model import DOWN, load_checkpoint
from predict import load_photo

K = 5  # largeur du faisceau, fixe dans le décodeur exporté


class Encoder(nn.Module):
    """Une seule image, sans remplissage : aucune colonne à masquer."""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, x):
        f = self.m.cnn(x)
        # embeddings plutôt que tranches [:w] : coremltools ne sait pas convertir une tranche de taille variable
        f = f + self.m.row.weight.T[None, :, :, None] + self.m.col(torch.arange(f.shape[3])).T[None, :, None, :]
        return f.flatten(2).transpose(1, 2)


def attention(mha, q, kv, mask=None):
    """nn.MultiheadAttention réécrit sans taille calculée à la volée : coremltools ne convertit pas la version de torch."""
    d, heads = mha.embed_dim, mha.num_heads
    wq, wk, wv = mha.in_proj_weight.split(d)
    bq, bk, bv = mha.in_proj_bias.split(d)
    split = lambda t: t.reshape(K, -1, heads, d // heads).transpose(1, 2)  # (B, têtes, n, d/têtes)
    q, k, v = split(q @ wq.T + bq), split(kv @ wk.T + bk), split(kv @ wv.T + bv)
    a = q @ k.transpose(-1, -2) / (d // heads) ** 0.5
    if mask is not None:
        a = a.masked_fill(mask, float("-inf"))
    out = (a.softmax(-1) @ v).transpose(1, 2).reshape(K, -1, d)
    return mha.out_proj(out)


class Decoder(nn.Module):
    """K débuts de formule -> log-probabilités du token suivant pour chacun (couches pré-normalisées, comme l'entraînement).

    shortcut: sans masque des PAD ; seules les hypothèses finies en contiennent et leur sortie est ignorée.
    """

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, y, memory):
        i = torch.arange(y.shape[1])
        x = self.m.tok(y) + self.m.pos(i)
        causal = i[None, :] > i[:, None]  # True : token futur, caché
        memory = memory.expand(K, -1, -1)
        for l in self.m.decoder.layers:
            h = l.norm1(x)
            x = x + attention(l.self_attn, h, h, causal)
            x = x + attention(l.multihead_attn, l.norm2(x), memory)
            x = x + l.linear2(l.activation(l.linear1(l.norm3(x))))
        return self.m.out(x[:, -1]).log_softmax(-1)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--ckpt", type=Path, default=Path("checkpoints/best.pt"))
    p.add_argument("--out", type=Path, default=Path("app/Model"))
    p.add_argument("--reference", type=int, default=0, help="nombre d'InkML de validation lus par Python")
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    model, itos = load_checkpoint(args.ckpt)
    model.float()
    (args.out / "vocab.json").write_text(json.dumps(itos, ensure_ascii=False))

    width = ct.RangeDim(32, MAX_WIDTH, default=256)
    enc = torch.jit.trace(Encoder(model).eval(), torch.zeros(1, 1, HEIGHT, 256))
    ct.convert(enc, inputs=[ct.TensorType("image", shape=(1, 1, HEIGHT, width))], outputs=[ct.TensorType("memory")],
               minimum_deployment_target=ct.target.macOS14, compute_precision=ct.precision.FLOAT32,
               ).save(str(args.out / "Encoder.mlpackage"))

    s = HEIGHT // DOWN
    y0, mem0 = torch.randint(4, len(itos), (K, 7), dtype=torch.int32), torch.randn(1, s * 16, model.out.in_features)
    with torch.no_grad():  # même calcul que le modèle d'origine
        want = model.decode(mem0.expand(K, -1, -1), None, y0)[:, -1].log_softmax(-1)
        assert torch.allclose(Decoder(model)(y0, mem0), want, atol=1e-4)
    dec = torch.jit.trace(Decoder(model).eval(), (y0, mem0))
    ct.convert(dec, inputs=[ct.TensorType("tokens", shape=(K, ct.RangeDim(1, MAX_LEN, default=7)), dtype=np.int32),
                            ct.TensorType("memory", shape=(1, ct.RangeDim(s * 2, s * MAX_WIDTH // DOWN, default=s * 16),
                                                           model.out.in_features))],
               outputs=[ct.TensorType("logp")],
               minimum_deployment_target=ct.target.macOS14, compute_precision=ct.precision.FLOAT32,
               ).save(str(args.out / "Decoder.mlpackage"))

    if args.reference:  # fichiers de test de l'app : formules lues par Python, et une photo avec son prétraitement
        tests = Path("app/Tests/Notes2LaTeXTests")
        vocab = Vocab(itos)
        files = sorted(Path("data/mathwriting-2024/valid").glob("*.inkml"))[: args.reference]
        ref = {}
        for f in files:
            img = render(read_inkml(f)[0])
            ids = model.beam_search(to_tensor(img)[None], torch.tensor([img.width]))[0]
            ref[f.name] = detokenize(vocab.decode(ids))
        (tests / "reference.json").write_text(json.dumps(ref, ensure_ascii=False, indent=1))
        render(read_inkml(files[0])[0]).save(tests / "ink-python.png")
        # fausse photo : encre grise sur papier clair, agrandie et lissée comme un appareil photo
        ink = np.asarray(render(read_inkml(files[0])[0])).astype(float)
        paper = 210 - 40 * np.linspace(0, 1, ink.shape[1])[None] - 150 * ink / 255
        photo = Image.fromarray(paper.clip(0, 255).astype(np.uint8)).resize((ink.shape[1] * 3, ink.shape[0] * 3), Image.BILINEAR)
        photo.save(tests / "photo.png")
        load_photo(tests / "photo.png").save(tests / "photo-python.png")

if __name__ == "__main__":
    main()
