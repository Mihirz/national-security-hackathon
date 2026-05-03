"""Lightweight transformer for ARGUS sensor fusion + trajectory prediction.

Architecture:
    sensor_window  : (B, T=16, F=16) -- last T sensor frames
    -> Linear F -> D=64
    -> add learned positional embedding
    -> 2 x TransformerEncoder (4 heads, ffn=128, gelu, pre-norm)
    -> take last token
    -> MLP heads:
         classification  (1)        target / no-target logit
         range / speed   (2)        normalized scalars
         trajectory      (H=10, 3)  future Δposition relative to ARGUS,
                                    spaced TRAJ_DT seconds apart

~70k parameters; runs at sub-millisecond per inference on M1 CPU.
"""
from __future__ import annotations

import torch
import torch.nn as nn

INPUT_DIM = 16
SEQ_LEN = 16
HORIZON = 10
TRAJ_DT = 1.0  # seconds between predicted waypoints

D_MODEL = 64
N_HEADS = 4
N_LAYERS = 2
FFN_DIM = 128


class ArgusTransformer(nn.Module):
    def __init__(self,
                 in_dim: int = INPUT_DIM,
                 seq_len: int = SEQ_LEN,
                 horizon: int = HORIZON,
                 d_model: int = D_MODEL,
                 n_heads: int = N_HEADS,
                 n_layers: int = N_LAYERS,
                 ffn_dim: int = FFN_DIM):
        super().__init__()
        self.seq_len = seq_len
        self.horizon = horizon

        self.input_proj = nn.Linear(in_dim, d_model)
        self.pos_emb = nn.Parameter(torch.randn(1, seq_len, d_model) * 0.02)

        layer = nn.TransformerEncoderLayer(
            d_model=d_model,
            nhead=n_heads,
            dim_feedforward=ffn_dim,
            activation="gelu",
            batch_first=True,
            norm_first=True,
            dropout=0.05,
        )
        self.encoder = nn.TransformerEncoder(layer, num_layers=n_layers)
        self.norm = nn.LayerNorm(d_model)

        self.head_cls = nn.Linear(d_model, 1)
        self.head_rng_spd = nn.Linear(d_model, 2)
        self.head_traj = nn.Sequential(
            nn.Linear(d_model, ffn_dim),
            nn.GELU(),
            nn.Linear(ffn_dim, horizon * 3),
        )

    def forward(self, x: torch.Tensor) -> dict:
        # x: (B, T, F)
        h = self.input_proj(x) + self.pos_emb[:, : x.size(1)]
        h = self.encoder(h)
        h = self.norm(h[:, -1])  # last token summarizes the window
        cls = self.head_cls(h).squeeze(-1)
        rs = self.head_rng_spd(h)
        traj = self.head_traj(h).view(-1, self.horizon, 3)
        return {"cls": cls, "rng_spd": rs, "traj": traj}
