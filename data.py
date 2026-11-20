"""Données MathWriting : lecture des InkML, rendu des traits en image, tokenizer LaTeX."""
import math
import random
import re
import xml.etree.ElementTree as ET
from pathlib import Path

import torch
from PIL import Image, ImageDraw
from torch.utils.data import Dataset, Sampler

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


def image_width(w: float, h: float) -> tuple[float, int]:
    """Échelle et largeur en pixels de l'image d'une formule de taille w x h."""
    # max(h, w/16) : un signe plat (« - ») ne doit pas être agrandi à l'infini
    scale = min((HEIGHT - 2 * MARGIN) / max(h, w / 16, 1e-6), (MAX_WIDTH - 2 * MARGIN) / max(w, 1e-6))
    return scale, max(32, min(MAX_WIDTH, int(w * scale) + 2 * MARGIN))


def render(strokes, augment: bool = False) -> Image.Image:
    """Traits -> image en niveaux de gris, traits blancs sur fond noir, hauteur HEIGHT."""
    if augment:  # petite rotation et inclinaison, comme une vraie écriture
        a, shear = math.radians(random.uniform(-4, 4)), random.uniform(-0.2, 0.2)
        ca, sa = math.cos(a), math.sin(a)
        strokes = [[(x * ca - y * sa + shear * y, x * sa + y * ca) for x, y in s] for s in strokes]
    xs = [x for s in strokes for x, _ in s]
    ys = [y for s in strokes for _, y in s]
    x0, y0 = min(xs), min(ys)
    scale, width = image_width(max(xs) - x0, max(ys) - y0)
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

def load_split(root: Path, split: str) -> dict:
    """Tous les traits d'un split dans un seul fichier binaire root/<split>.pt.

    Construit au premier appel (lecture des InkML, quelques minutes), puis ouvert en mmap :
    lire un exemple ne coûte plus qu'une tranche de tableau au lieu d'un fichier XML.
    """
    path = root / f"{split}.pt"
    if not path.exists():
        pts, stroke_end, sample_end, tokens, widths = [], [0], [0], [], []
        for f in sorted((root / split).glob("*.inkml")):
            strokes, label = read_inkml(f)
            toks = tokenize(label)
            if len(toks) + 2 > MAX_LEN:
                continue
            ts = [torch.tensor(s, dtype=torch.float32) for s in strokes]
            p = torch.cat(ts)
            lo = p.min(0).values
            w, h = (p.max(0).values - lo).tolist()
            norm = max(h, w / 16, 1e-6)  # coordonnées ramenées vers 0..16 : float16 reste précis
            pts.append(((p - lo) / norm).half())
            for s in ts:
                stroke_end.append(stroke_end[-1] + len(s))
            sample_end.append(sample_end[-1] + len(ts))
            tokens.append(toks)
            widths.append(image_width(w / norm, h / norm)[1])
        torch.save({"points": torch.cat(pts), "stroke_end": torch.tensor(stroke_end),
                    "sample_end": torch.tensor(sample_end), "tokens": tokens, "widths": torch.tensor(widths)}, path)
    return torch.load(path, mmap=True)


class MathWriting(Dataset):
    def __init__(self, root: Path, split: str, vocab: Vocab, augment: bool = False, limit: int | None = None):
        self.path, self.augment = root / f"{split}.pt", augment
        d = load_split(root, split)
        self.seqs = [vocab.encode(t) for t in d["tokens"][:limit]]
        self.widths = d["widths"][:limit].tolist()
        self.d = None  # ouvert dans chaque processus de chargement, en mmap (mémoire partagée)

    def __getstate__(self):
        return {**self.__dict__, "d": None}

    def __len__(self):
        return len(self.seqs)

    def __getitem__(self, i):
        if self.d is None:
            self.d = torch.load(self.path, mmap=True)
        a, b = self.d["sample_end"][i : i + 2].tolist()
        bounds = self.d["stroke_end"][a : b + 1].tolist()
        pts = self.d["points"][bounds[0] : bounds[-1]].float().tolist()
        strokes = [pts[s - bounds[0] : e - bounds[0]] for s, e in zip(bounds, bounds[1:])]
        return to_tensor(render(strokes, self.augment)), torch.tensor(self.seqs[i])


class WidthBatches(Sampler):
    """Lots de formules de largeurs proches : moins de remplissage, donc moins de calcul.

    Ordre aléatoire à chaque époque ; avec seed, toujours le même (pour la validation).
    """

    def __init__(self, widths: list[int], batch: int, seed: int | None = None):
        self.widths, self.batch, self.seed = widths, batch, seed

    def __iter__(self):
        g = torch.Generator().manual_seed(self.seed if self.seed is not None else random.randrange(2**31))
        idx = torch.randperm(len(self.widths), generator=g).tolist()
        chunk, batches = self.batch * 64, []
        for c in range(0, len(idx), chunk):
            part = sorted(idx[c : c + chunk], key=self.widths.__getitem__)
            batches += [part[i : i + self.batch] for i in range(0, len(part), self.batch)]
        return iter([batches[k] for k in torch.randperm(len(batches), generator=g).tolist()])

    def __len__(self):
        return math.ceil(len(self.widths) / self.batch)


def round_up(n: int, m: int) -> int:
    return -(-n // m) * m


def collate(batch):
    """Complète images (fond noir) et séquences (PAD) jusqu'à des tailles arrondies.

    Le GPU du Mac recompile ses calculs à chaque nouvelle forme de tenseur : arrondir
    la largeur à 128 px et la longueur à 16 tokens limite le nombre de formes (×2,4 plus rapide).
    """
    imgs, seqs = zip(*batch)
    widths = torch.tensor([im.shape[-1] for im in imgs])
    x = torch.zeros(len(imgs), 1, HEIGHT, min(MAX_WIDTH, round_up(int(widths.max()), 128)))
    for i, im in enumerate(imgs):
        x[i, :, :, : im.shape[-1]] = im
    y = torch.full((len(seqs), min(MAX_LEN, round_up(max(map(len, seqs)), 16))), PAD)
    for i, s in enumerate(seqs):
        y[i, : len(s)] = s
    return x, widths, y
