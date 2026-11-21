"""Encodeur CNN + décodeur Transformer : image de formule -> tokens LaTeX."""
import torch
from torch import nn

from data import BOS, EOS, HEIGHT, MAX_LEN, MAX_WIDTH, PAD

DOWN = 16  # facteur de réduction de l'encodeur (4 blocs à pas 2)


def block(cin, cout):
    return nn.Sequential(
        nn.Conv2d(cin, cout, 3, stride=2, padding=1, bias=False), nn.BatchNorm2d(cout), nn.ReLU(inplace=True),
        nn.Conv2d(cout, cout, 3, padding=1, bias=False), nn.BatchNorm2d(cout), nn.ReLU(inplace=True),
    )


class Im2Latex(nn.Module):
    def __init__(self, vocab_size: int, d: int = 256, heads: int = 8, layers: int = 3):
        super().__init__()
        self.cnn = nn.Sequential(block(1, 32), block(32, 64), block(64, 128), block(128, d))
        self.row = nn.Embedding(HEIGHT // DOWN, d)  # position 2D apprise : ligne + colonne
        self.col = nn.Embedding(MAX_WIDTH // DOWN, d)
        self.tok = nn.Embedding(vocab_size, d, padding_idx=PAD)
        self.pos = nn.Embedding(MAX_LEN, d)
        layer = nn.TransformerDecoderLayer(d, heads, 4 * d, dropout=0.1, batch_first=True, norm_first=True)
        self.decoder = nn.TransformerDecoder(layer, layers)
        self.out = nn.Linear(d, vocab_size)

    def encode(self, x, widths):
        f = self.cnn(x)  # (B, d, H/16, W/16)
        b, d, h, w = f.shape
        f = f + self.row.weight[:h].T[None, :, :, None] + self.col.weight[:w].T[None, :, None, :]
        memory = f.flatten(2).transpose(1, 2)  # (B, h*w, d)
        # colonnes qui ne viennent que du remplissage : masquées pour l'attention
        cols = torch.arange(w, device=x.device)[None] >= ((widths.to(x.device) + DOWN - 1) // DOWN)[:, None]
        return memory, cols[:, None, :].expand(b, h, w).reshape(b, h * w)

    def decode(self, memory, mem_mask, y):
        n = y.shape[1]
        t = self.tok(y) + self.pos.weight[:n]
        causal = nn.Transformer.generate_square_subsequent_mask(n, device=y.device, dtype=torch.bool)
        h = self.decoder(t, memory, tgt_mask=causal, tgt_key_padding_mask=y == PAD,
                         memory_key_padding_mask=mem_mask)
        return self.out(h)

    def forward(self, x, widths, y_in):
        return self.decode(*self.encode(x, widths), y_in)

    @torch.no_grad()
    def beam_search(self, x, widths, k: int = 5, max_len: int = MAX_LEN) -> list[list[int]]:
        """Garde les k débuts de formule les plus probables à chaque pas ; k=1 : décodage glouton."""
        memory, mask = self.encode(x, widths)
        b, dev = x.shape[0], x.device
        memory, mask = memory.repeat_interleave(k, 0), mask.repeat_interleave(k, 0)
        y = torch.full((b * k, 1), BOS, device=dev)
        scores = torch.full((b, k), float("-inf"), device=dev)
        scores[:, 0] = 0  # au départ, une seule hypothèse par image
        done = torch.zeros(b * k, dtype=torch.bool, device=dev)
        for _ in range(max_len - 1):
            logp = self.decode(memory, mask, y)[:, -1].float().log_softmax(-1)
            logp[done] = float("-inf")
            logp[done, PAD] = 0  # une hypothèse finie ne s'allonge que de PAD, sans coût
            v = logp.shape[-1]
            scores, idx = (scores.view(-1, 1) + logp).view(b, k * v).topk(k, -1)
            src = (idx // v + torch.arange(b, device=dev)[:, None] * k).view(-1)
            tok = (idx % v).view(-1)
            y = torch.cat([y[src], tok[:, None]], 1)
            done = done[src] | (tok == EOS)
            if done.all():
                break
        rows = y.view(b, k, -1)[torch.arange(b, device=dev), scores.argmax(-1), 1:].tolist()  # sans BOS
        return [r[: r.index(EOS)] if EOS in r else r for r in rows]


def load_checkpoint(path, device: str = "cpu"):
    """-> (modèle en mode évaluation, liste des tokens)."""
    ckpt = torch.load(path, map_location="cpu")
    model = Im2Latex(len(ckpt["vocab"]), **ckpt.get("config", {}))
    model.load_state_dict(ckpt["model"])
    return model.to(device).eval(), ckpt["vocab"]
