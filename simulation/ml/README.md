# ARGUS local AI model

Tiny PyTorch MLP (~5.4k params) that fuses ARGUS sensor outputs (infrasound,
SWIR, EO) into a target-presence probability and a coarse range/speed
estimate. Designed to run locally on an M1 MacBook Pro (CPU is plenty fast;
MPS works for the dataset generator but training is more reliable on CPU).

## Files
- `sim_physics.py` — Python mirror of the GDScript sensor physics. Emits
  rollouts and converts `SensorReading` rows into the 16-feature vector the
  model consumes.
- `gen_dataset.py` — rolls N synthetic engagements (mix of HCM targets and
  slow decoys) and writes `dataset.npz`.
- `model.py` — `ArgusNet`: 16 → 64 → 64 → 3 GELU MLP.
- `train.py` — multi-task loss (BCE on classifier, smooth-L1 on
  range/speed for positives only).
- `infer.py` — `--demo` prints predictions vs. truth for one rollout;
  `--serve` exposes a UDP JSON bridge on port 9999.

## End-to-end
```bash
cd simulation/ml
python3 gen_dataset.py --episodes 800 --steps 150 --out dataset.npz
python3 train.py --device cpu --epochs 20 --out argus_model.pt
python3 infer.py --demo                # smoke test
python3 infer.py --serve               # UDP server on 127.0.0.1:9999
```

## Hooking the model into the Godot sim
Open `simulation/scenes/main.tscn`, select the `Controller` node, and toggle
`enable_ml_bridge` on. With the inference server running, the bridge sends a
16-float feature vector every `ml_query_period_s` seconds and reads back
`p_target`, `range_m`, `speed_mps`. See `scripts/ml_bridge.gd`.

## Features (must stay in sync with `sim_physics.FEATURE_NAMES`)
1. `inf_anomaly`
2. `sin(inf_bearing)`
3. `cos(inf_bearing)`
4. `inf_elevation`
5. `swir_intensity`
6. `sin(swir_bearing)`
7. `cos(swir_bearing)`
8. `swir_elevation`
9. `swir_range / 100 km`
10. `swir_lock`
11. `eo_class_conf`
12. `sin(eo_bearing)`
13. `cos(eo_bearing)`
14. `eo_elevation`
15. `eo_range / 100 km`
16. `eo_visual`

## Outputs
- `p_target` ∈ [0,1] — fused target-presence probability.
- `range_m` — model's range estimate (meters).
- `speed_mps` — model's speed estimate (m/s).
