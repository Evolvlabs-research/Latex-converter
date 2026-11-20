"""Données MathWriting : lecture des InkML, rendu des traits en image, tokenizer LaTeX."""
import json
import math
import random
import re
import xml.etree.ElementTree as ET
from pathlib import Path

import torch
from PIL import Image, ImageDraw
from torch.utils.data import Dataset

NS = {"ink": "http://www.w3.org/2003/InkML"}
TOKEN_RE = re.compile(r"\\[a-zA-Z]+|\\.|\S")
SPECIALS = ["<pad>", "<bos>", "<eos>", "<unk>"]
PAD, BOS, EOS, UNK = range(4)
HEIGHT, MAX_WIDTH, MARGIN = 128, 1024, 8
MAX_LEN = 200  # tokens, BOS/EOS compris ; les formules plus longues sont écartées


# ---------- texte ----------

def tokenize(latex: str) -> list[str]:
    # shortcut: les espaces dans \text{...} sont perdus, à revoir si le texte compte.
    return TOKEN_RE.findall(latex)


def detokenize(tokens: list[str]) -> str:
    out = ""
    for tok in tokens:
        if out and re.search(r"\\[a-zA-Z]+$", out) and tok[0].isalpha():
            out += " "  # \alpha x, pas \alphax
        out += tok
    return out


class Vocab:
    def __init__(self, tokens: list[str]):
        self.itos = SPECIALS + sorted(set(tokens) - set(SPECIALS))
        self.stoi = {t: i for i, t in enumerate(self.itos)}

    def encode(self, tokens: list[str]) -> list[int]:
        return [BOS] + [self.stoi.get(t, UNK) for t in tokens] + [EOS]

    def decode(self, ids: list[int]) -> list[str]:
        return [self.itos[i] for i in ids if i > UNK]

    def __len__(self):
        return len(self.itos)


# ---------- encre ----------

def read_inkml(path: Path) -> tuple[list[list[tuple[float, float]]], str]:
    root = ET.parse(path).getroot()
    ann = {a.get("type"): a.text for a in root.findall("ink:annotation", NS)}
    strokes = [[tuple(map(float, p.split()[:2])) for p in t.text.strip().split(",")]
               for t in root.findall("ink:trace", NS)]
    return strokes, ann.get("normalizedLabel") or ann["label"]


def render(strokes, augment: bool = False) -> Image.Image:
    """Traits -> image en niveaux de gris, traits blancs sur fond noir, hauteur HEIGHT."""
    if augment:  # petite rotation et inclinaison, comme une vraie écriture
        a, shear = math.radians(random.uniform(-4, 4)), random.uniform(-0.2, 0.2)
        ca, sa = math.cos(a), math.sin(a)
        strokes = [[(x * ca - y * sa + shear * y, x * sa + y * ca) for x, y in s] for s in strokes]
    xs = [x for s in strokes for x, _ in s]
    ys = [y for s in strokes for _, y in s]
    x0, y0 = min(xs), min(ys)
    w, h = max(xs) - x0, max(ys) - y0
    # max(h, w/16) : un signe plat (« - ») ne doit pas être agrandi à l'infini
    scale = min((HEIGHT - 2 * MARGIN) / max(h, w / 16, 1e-6), (MAX_WIDTH - 2 * MARGIN) / max(w, 1e-6))
    width = max(32, min(MAX_WIDTH, int(w * scale) + 2 * MARGIN))
    img = Image.new("L", (width, HEIGHT), 0)
    draw = ImageDraw.Draw(img)
    line = random.randint(2, 5) if augment else 3
    for s in strokes:
        pts = [((x - x0) * scale + MARGIN, (y - y0) * scale + MARGIN) for x, y in s]
        if len(pts) == 1:
            pts = pts * 2  # un point isolé reste visible
        draw.line(pts, fill=255, width=line, joint="curve")
    return img


def to_tensor(img: Image.Image) -> torch.Tensor:
    return torch.frombuffer(bytearray(img.tobytes()), dtype=torch.uint8).view(1, img.height, img.width).float() / 255


# ---------- jeu de données ----------

def load_index(root: Path, split: str) -> list[tuple[str, list[str]]]:
    """Liste (fichier, tokens) d'un split, mise en cache dans root/<split>.index.json."""
    cache = root / f"{split}.index.json"
    if cache.exists():
        return json.loads(cache.read_text())
    items = []
    for f in sorted((root / split).glob("*.inkml")):
        tokens = tokenize(read_inkml(f)[1])
        if len(tokens) + 2 <= MAX_LEN:
            items.append((f.name, tokens))
    cache.write_text(json.dumps(items))
    return items


class MathWriting(Dataset):
    def __init__(self, root: Path, split: str, vocab: Vocab, augment: bool = False, limit: int | None = None):
        self.dir, self.vocab, self.augment = root / split, vocab, augment
        self.items = load_index(root, split)[:limit]

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        name, tokens = self.items[i]
        strokes, _ = read_inkml(self.dir / name)
        return to_tensor(render(strokes, self.augment)), torch.tensor(self.vocab.encode(tokens))


def collate(batch):
    """Complète les images à droite (fond noir) et les séquences avec PAD."""
    imgs, seqs = zip(*batch)
    widths = torch.tensor([im.shape[-1] for im in imgs])
    x = torch.zeros(len(imgs), 1, HEIGHT, int(widths.max()))
    for i, im in enumerate(imgs):
        x[i, :, :, : im.shape[-1]] = im
    y = torch.nn.utils.rnn.pad_sequence(seqs, batch_first=True, padding_value=PAD)
    return x, widths, y
