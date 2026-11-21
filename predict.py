"""Lit une formule : uv run predict.py formule.jpg [autre.png | trace.inkml ...]"""
import argparse
from pathlib import Path

import torch
from PIL import Image, ImageOps

from data import HEIGHT, MARGIN, MAX_WIDTH, Vocab, detokenize, read_inkml, render, to_tensor
from model import load_checkpoint


def load_photo(path: Path) -> Image.Image:
    """Photo (encre sombre sur papier clair) -> même aspect que l'entraînement : traits blancs sur noir."""
    img = ImageOps.exif_transpose(Image.open(path)).convert("L")
    img = ImageOps.invert(ImageOps.autocontrast(img, cutoff=2))
    # shortcut: seuil fixe, sensible à l'éclairage ; passer à un seuil adaptatif si les photos sont inégales.
    img = img.point(lambda v: 255 if v > 110 else 0)
    box = img.getbbox() or (0, 0, img.width, img.height)
    img = img.crop(box)
    scale = min((HEIGHT - 2 * MARGIN) / img.height, (MAX_WIDTH - 2 * MARGIN) / img.width)
    img = img.resize((max(1, int(img.width * scale)), max(1, int(img.height * scale))), Image.LANCZOS)
    canvas = Image.new("L", (max(32, img.width + 2 * MARGIN), HEIGHT), 0)
    canvas.paste(img, (MARGIN, (HEIGHT - img.height) // 2))
    return canvas


def main():
    p = argparse.ArgumentParser()
    p.add_argument("files", nargs="+", type=Path)
    p.add_argument("--ckpt", type=Path, default=Path("checkpoints/best.pt"))
    args = p.parse_args()

    model, itos = load_checkpoint(args.ckpt)
    vocab = Vocab(itos)

    for f in args.files:
        img = render(read_inkml(f)[0]) if f.suffix == ".inkml" else load_photo(f)
        ids = model.beam_search(to_tensor(img)[None], torch.tensor([img.width]))[0]
        print(f"{f.name}: {detokenize(vocab.decode(ids))}")


if __name__ == "__main__":
    main()
