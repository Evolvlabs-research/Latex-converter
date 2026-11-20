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
    def greedy(self, x, widths, max_len: int = MAX_LEN) -> list[list[int]]:
        memory, mask = self.encode(x, widths)
        y = torch.full((x.shape[0], 1), BOS, device=x.device)
        done = torch.zeros(x.shape[0], dtype=torch.bool, device=x.device)
        for _ in range(max_len - 1):
            nxt = self.decode(memory, mask, y)[:, -1].argmax(-1)
            nxt = nxt.masked_fill(done, PAD)
            y = torch.cat([y, nxt[:, None]], 1)
            done |= nxt == EOS
            if done.all():
                break
        rows = y[:, 1:].tolist()  # sans BOS ; on coupe au premier EOS
        return [r[: r.index(EOS)] if EOS in r else r for r in rows]
