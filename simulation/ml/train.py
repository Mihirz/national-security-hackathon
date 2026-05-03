"""Train ArgusTransformer on the windowed sensor dataset.

    python train.py --device cpu --epochs 20 --out argus_model.pt

Multi-task loss:
    L = BCE(cls)
      + 0.5 * SmoothL1(range, speed)   on positives only
      + 1.0 * SmoothL1(trajectory)     on positives only
"""
from __future__ import annotations

import argparse
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader, TensorDataset

from model import ArgusTransformer


def pick_device(prefer: str = "auto") -> torch.device:
    if prefer == "cpu":
        return torch.device("cpu")
    if prefer in ("mps", "auto") and torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def split(X, *Ys, val_frac=0.1, seed=0):
    rng = np.random.default_rng(seed)
    idx = rng.permutation(len(X))
    n_val = int(len(X) * val_frac)
    v, t = idx[:n_val], idx[n_val:]
    train = [X[t]] + [Y[t] for Y in Ys]
    val = [X[v]] + [Y[v] for Y in Ys]
    return train, val


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=str, default="dataset.npz")
    ap.add_argument("--out", type=str, default="argus_model.pt")
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--batch", type=int, default=256)
    ap.add_argument("--lr", type=float, default=8e-4)
    ap.add_argument("--device", type=str, default="auto", choices=["auto", "cpu", "mps"])
    args = ap.parse_args()

    device = pick_device(args.device)
    print(f"device: {device}")

    z = np.load(args.data, allow_pickle=True)
    X = z["X"].astype(np.float32)
    Ycls = z["Ycls"].astype(np.float32)
    Yrs = z["Yrs"].astype(np.float32)
    Ytraj = z["Ytraj"].astype(np.float32)
    seq_len = int(z["seq_len"])
    horizon = int(z["horizon"])
    pos_norm = float(z["pos_norm_m"])
    print(f"data: X={X.shape} traj={Ytraj.shape} pos_norm={pos_norm}")

    # Per-feature standardization (computed over all timesteps).
    flat = X.reshape(-1, X.shape[-1])
    mean = flat.mean(axis=0)
    std = flat.std(axis=0) + 1e-6
    Xn = (X - mean) / std

    (Xtr, Ctr, Rtr, Ttr), (Xv, Cv, Rv, Tv) = split(Xn, Ycls, Yrs, Ytraj)
    train_ds = TensorDataset(*(torch.from_numpy(a) for a in [Xtr, Ctr, Rtr, Ttr]))
    val_ds = TensorDataset(*(torch.from_numpy(a) for a in [Xv, Cv, Rv, Tv]))
    train_dl = DataLoader(train_ds, batch_size=args.batch, shuffle=True, drop_last=True)
    val_dl = DataLoader(val_ds, batch_size=args.batch * 2)

    model = ArgusTransformer(seq_len=seq_len, horizon=horizon).to(device)
    n_params = sum(p.numel() for p in model.parameters())
    print(f"model params: {n_params}")
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)

    for epoch in range(args.epochs):
        t0 = time.time()
        model.train()
        for xb, cb, rb, tb in train_dl:
            xb = xb.to(device); cb = cb.to(device); rb = rb.to(device); tb = tb.to(device)
            out = model(xb)
            cls_loss = F.binary_cross_entropy_with_logits(out["cls"], cb)
            mask = cb > 0.5
            if mask.any():
                rs_loss = F.smooth_l1_loss(out["rng_spd"][mask], rb[mask])
                tj_loss = F.smooth_l1_loss(out["traj"][mask], tb[mask])
            else:
                rs_loss = torch.zeros((), device=device)
                tj_loss = torch.zeros((), device=device)
            loss = cls_loss + 0.5 * rs_loss + 1.0 * tj_loss
            opt.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
        sched.step()

        # Validation.
        model.eval()
        v_cls_loss = 0.0; v_acc = 0.0; v_traj_mae = 0.0; n = 0; pos_n = 0
        with torch.no_grad():
            for xb, cb, rb, tb in val_dl:
                xb = xb.to(device); cb = cb.to(device); tb = tb.to(device)
                out = model(xb)
                v_cls_loss += float(F.binary_cross_entropy_with_logits(out["cls"], cb)) * len(xb)
                v_acc += float(((out["cls"] > 0.0).float() == cb).float().sum())
                mask = cb > 0.5
                if mask.any():
                    err = (out["traj"][mask] - tb[mask]).abs().mean() * pos_norm
                    v_traj_mae += float(err) * int(mask.sum())
                    pos_n += int(mask.sum())
                n += len(xb)
        print(f"epoch {epoch+1:2d}  cls_loss={v_cls_loss/n:.4f}  "
              f"acc={v_acc/n:.3f}  traj_mae={v_traj_mae/max(pos_n,1):.0f}m  "
              f"({time.time()-t0:.1f}s)")

    out = Path(args.out)
    torch.save({
        "state_dict": model.state_dict(),
        "feat_mean": mean,
        "feat_std": std,
        "seq_len": seq_len,
        "horizon": horizon,
        "pos_norm_m": pos_norm,
    }, out)
    print(f"saved {out}")


if __name__ == "__main__":
    main()
