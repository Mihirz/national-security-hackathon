"""Generate a windowed sensor dataset for the transformer.

Each sample is a (SEQ_LEN, F) window of sensor frames + labels:
    cls    : 1 if the engagement is a real HCM target
    rng    : current target range / 100 km
    spd    : current target speed / 2500 m/s
    traj   : (HORIZON, 3) future ARGUS-relative position deltas / 100 km,
             sampled at TRAJ_DT-second intervals after the window's last frame.
"""
from __future__ import annotations

import argparse
import time
from pathlib import Path

import numpy as np

from sim_physics import (
    FEATURE_NAMES,
    reading_to_features,
    roll_engagement,
)

POS_NORM_M = 100000.0  # match infer/bridge
VEL_NORM_MPS = 2500.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--episodes", type=int, default=2000)
    ap.add_argument("--steps", type=int, default=240)
    ap.add_argument("--dt", type=float, default=0.1)
    ap.add_argument("--seq_len", type=int, default=16)
    ap.add_argument("--horizon", type=int, default=10)
    ap.add_argument("--traj_dt", type=float, default=1.0,
                    help="seconds between predicted future waypoints")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", type=str, default="dataset.npz")
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    stride = max(int(round(args.traj_dt / args.dt)), 1)
    samples_X = []
    samples_cls = []
    samples_rs = []
    samples_traj = []
    t0 = time.time()

    for ep in range(args.episodes):
        rows = roll_engagement(rng, n_steps=args.steps, dt=args.dt)
        feats_seq = np.stack([reading_to_features(r) for r in rows])
        # Slide a window across the episode.
        last_feasible = len(rows) - args.horizon * stride - 1
        if last_feasible < args.seq_len:
            continue
        # Sample windows densely.
        for end in range(args.seq_len, last_feasible, 2):
            window = feats_seq[end - args.seq_len:end]
            r_now = rows[end - 1]
            traj = []
            for h in range(1, args.horizon + 1):
                rh = rows[end - 1 + h * stride]
                traj.append([
                    rh.rel_x_m / POS_NORM_M,
                    rh.rel_y_m / POS_NORM_M,
                    rh.rel_z_m / POS_NORM_M,
                    rh.vel_x_mps / VEL_NORM_MPS,
                    rh.vel_y_mps / VEL_NORM_MPS,
                    rh.vel_z_mps / VEL_NORM_MPS,
                ])
            traj = np.array(traj, dtype=np.float32)
            samples_X.append(window.astype(np.float32))
            samples_cls.append(np.float32(r_now.is_target))
            samples_rs.append(np.array([
                r_now.target_range_m / POS_NORM_M,
                r_now.target_speed_mps / 2500.0,
            ], dtype=np.float32))
            samples_traj.append(traj)
        if (ep + 1) % 200 == 0:
            print(f"  episode {ep+1}/{args.episodes}  windows={len(samples_X)}")

    X = np.stack(samples_X)
    Ycls = np.stack(samples_cls)
    Yrs = np.stack(samples_rs)
    Ytraj = np.stack(samples_traj)
    out = Path(args.out)
    np.savez_compressed(
        out,
        X=X,
        Ycls=Ycls,
        Yrs=Yrs,
        Ytraj=Ytraj,
        feature_names=np.array(FEATURE_NAMES),
        seq_len=np.int32(args.seq_len),
        horizon=np.int32(args.horizon),
        traj_dt=np.float32(args.traj_dt),
        pos_norm_m=np.float32(POS_NORM_M),
        vel_norm_mps=np.float32(VEL_NORM_MPS),
    )
    print(f"wrote {out}  X={X.shape}  Ytraj={Ytraj.shape}  ({time.time()-t0:.1f}s)")
    print(f"positive rate: {float(Ycls.mean()):.3f}")


if __name__ == "__main__":
    main()
