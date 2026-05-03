"""ARGUS local inference (transformer).

    python infer.py --demo
    python infer.py --serve --port 9999

UDP protocol (JSON):
  request:  {"window": [[f1..f16], ..., [f1..f16]]}      # length == seq_len
       or:  {"features": [f1..f16]}                       # server keeps a
                                                          # per-source rolling
                                                          # window keyed by addr
  reply:    {"p_target": float, "range_m": float, "speed_mps": float,
             "trajectory": [[x,y,z], ...]}                # ARGUS-relative meters
"""
from __future__ import annotations

import argparse
import collections
import json
import socket

import numpy as np
import torch

from model import ArgusTransformer
from sim_physics import (
    FEATURE_NAMES,
    reading_to_features,
    roll_engagement,
)


def load(model_path: str, device: str = "cpu"):
    blob = torch.load(model_path, map_location=device, weights_only=False)
    seq_len = int(blob.get("seq_len", 16))
    horizon = int(blob.get("horizon", 10))
    pos_norm = float(blob.get("pos_norm_m", 100000.0))
    model = ArgusTransformer(seq_len=seq_len, horizon=horizon).to(device)
    model.load_state_dict(blob["state_dict"])
    model.eval()
    mean = torch.tensor(blob["feat_mean"], dtype=torch.float32, device=device)
    std = torch.tensor(blob["feat_std"], dtype=torch.float32, device=device)
    return model, mean, std, seq_len, horizon, pos_norm


def predict(model, mean, std, window: np.ndarray, pos_norm: float) -> dict:
    with torch.no_grad():
        x = torch.from_numpy(window).float().unsqueeze(0)  # (1, T, F)
        x = (x - mean) / std
        out = model(x)
        cls_logit = float(out["cls"].squeeze())
        rs = out["rng_spd"].squeeze(0).cpu().numpy()
        traj = out["traj"].squeeze(0).cpu().numpy() * pos_norm  # meters
    p = 1.0 / (1.0 + np.exp(-cls_logit))
    return {
        "p_target": float(p),
        "range_m": float(rs[0]) * pos_norm,
        "speed_mps": float(rs[1]) * 2500.0,
        "trajectory": [[float(x), float(y), float(z)] for x, y, z in traj],
    }


def cmd_demo(args):
    model, mean, std, seq_len, horizon, pos_norm = load(args.model)
    rng = np.random.default_rng(args.seed)
    rows = roll_engagement(rng, n_steps=160, dt=0.1)
    feats = np.stack([reading_to_features(r) for r in rows])
    print(f"{'t':>4} {'truth':>6} {'p_t':>6} {'rng_pred':>9} {'rng_true':>9} "
          f"{'next_dx':>9} {'next_dy':>9} {'next_dz':>9}")
    for end in range(seq_len, len(rows), 8):
        window = feats[end - seq_len:end]
        r = rows[end - 1]
        out = predict(model, mean, std, window, pos_norm)
        n0 = out["trajectory"][0]
        print(f"{end:>4} {r.is_target:>6d} {out['p_target']:>6.3f} "
              f"{out['range_m']:>9.0f} {r.target_range_m:>9.0f} "
              f"{n0[0]:>9.0f} {n0[1]:>9.0f} {n0[2]:>9.0f}")


def cmd_serve(args):
    model, mean, std, seq_len, horizon, pos_norm = load(args.model)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.host, args.port))
    print(f"argus-transformer listening on {args.host}:{args.port}  "
          f"seq_len={seq_len} horizon={horizon}")

    # Per-source rolling buffer for clients sending one frame at a time.
    buffers: dict = collections.defaultdict(lambda: collections.deque(maxlen=seq_len))

    while True:
        data, addr = sock.recvfrom(8192)
        try:
            msg = json.loads(data.decode("utf-8"))
            if "window" in msg:
                w = np.array(msg["window"], dtype=np.float32)
                if w.shape != (seq_len, 16):
                    raise ValueError(f"window shape {w.shape}, want ({seq_len},16)")
                out = predict(model, mean, std, w, pos_norm)
            else:
                if "features" in msg:
                    feats = np.array(msg["features"], dtype=np.float32)
                else:
                    feats = np.array([float(msg[k]) for k in FEATURE_NAMES], dtype=np.float32)
                buf = buffers[addr]
                buf.append(feats)
                while len(buf) < seq_len:
                    buf.append(feats)  # left-pad with first frame
                w = np.stack(list(buf))
                out = predict(model, mean, std, w, pos_norm)
        except Exception as e:
            out = {"error": str(e)}
        sock.sendto(json.dumps(out).encode("utf-8"), addr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", type=str, default="argus_model.pt")
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--serve", action="store_true")
    ap.add_argument("--host", type=str, default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9999)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    if args.serve:
        cmd_serve(args)
    else:
        cmd_demo(args)


if __name__ == "__main__":
    main()
