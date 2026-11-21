"""Lit une formule : uv run predict.py formule.jpg [autre.png | trace.inkml ...]"""
import argparse
import sys
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
    p.add_argument("files", nargs="*", type=Path)
    p.add_argument("--ckpt", type=Path, default=Path("checkpoints/best.pt"))
    p.add_argument("--serve", action="store_true",
                   help="un chemin par ligne sur l'entrée standard, une formule par ligne en sortie (modèle chargé une fois)")
    args = p.parse_args()

    model, itos = load_checkpoint(args.ckpt)
    vocab = Vocab(itos)

    def read(f: Path) -> str:
        img = render(read_inkml(f)[0]) if f.suffix == ".inkml" else load_photo(f)
        ids = model.beam_search(to_tensor(img)[None], torch.tensor([img.width]))[0]
        return detokenize(vocab.decode(ids))

    if args.serve:  # utilisé par l'app Nabla
        for line in iter(sys.stdin.readline, ""):
            try:
                print(read(Path(line.rstrip("\n"))), flush=True)
            except Exception as e:  # une image illisible ne doit pas arrêter le serveur
                print("ERREUR " + str(e).replace("\n", " "), flush=True)
        return

    for f in args.files:
        print(f"{f.name}: {read(f)}")


if __name__ == "__main__":
    main()
