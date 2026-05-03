# Project ARGUS — Godot Intercept Simulation

Phase 1 of the ARGUS deliverable per `Project Description.pdf`: a custom
Godot-based simulation used to train and validate the sensor-fusion and
interception algorithms.

## Run it

1. Install **Godot 4.3+** (Standard, not the .NET build).
2. `Godot → Import` → select `simulation/project.godot`.
3. Press **F5** (or the Play button). Main scene is `scenes/main.tscn`.

## What's modeled

| PDF requirement | Implementation |
|---|---|
| Stratospheric solar glider, 60–90 kft loiter, multi-day endurance | `argus_drone.gd` — constant-rate loiter at mid-band altitude; cruise speed = 28 m/s |
| Hypersonic cruise missile target | `hcm_target.gd` — Mach ~5 cruise with vertical band 18–25 km |
| Adversary evasion heuristics: randomized glide maneuvers, erratic altitude changes | `_step_evasion()` re-rolls lateral g-bias and altitude target on a randomized cadence |
| RF blackout from plasma sheathing | `plasma_blackout` flag engaged on speed × maneuver-load; HUD warns; fusion adds an IR+acoustic confirmation bonus during blackout |
| Multi-modal sensors (IR, EO camera, air pressure / acoustic) | `sensor_swir.gd`, `sensor_eo.gd`, `sensor_infrasound.gd` |
| Tiered detection / power-gated fusion: infrasound → SWIR → satellite uplink only on confirmed threats | `power_manager.gd` — `IDLE → DETECT → TRACK → ENGAGE` state machine with hysteresis; `draw_w` shown live |
| Sensor fusion AI estimating target state without exact coordinates | `sensor_fusion.gd` — inverse-variance circular bearing fusion + range-from-modality + EMA tracker. Reads only sensor outputs, never the truth state |
| Cost feasibility from COTS sensors / passive platform | Reflected in modeled per-sensor power budget; ENGAGE-only uplink |
| Clean cool UI | `hud.gd` — code-drawn mission HUD with tacmap, sensor stack, tier banner, blackout warning |

## Controls

- **R** — respawn HCM with new random heading / altitude profile
- **T** — toggle the truth marker (red sphere) for ground-truth comparison
- **C** — cycle camera (orbit / chase ARGUS / chase HCM)

## Files

```
simulation/
├── project.godot
├── icon.svg
├── scenes/main.tscn
└── scripts/
    ├── sim_constants.gd     # world units, alt bands, tier thresholds
    ├── sim_controller.gd    # orchestrates sensors, fusion, power each tick
    ├── argus_drone.gd       # passive solar-glider loiter
    ├── hcm_target.gd        # hypersonic adversary + evasion + plasma model
    ├── sensor_infrasound.gd # always-on tripwire (long range, low SNR)
    ├── sensor_swir.gd       # IR thermal-verification (mid power)
    ├── sensor_eo.gd         # EO camera (high fidelity, short range)
    ├── sensor_fusion.gd     # multi-modal estimator
    ├── power_manager.gd     # tiered power-gated state machine
    ├── orbit_camera.gd      # cinematic camera
    └── hud.gd               # mission-control overlay
```

The estimator surface is the seam where the Phase-3 trained policy will plug
in: today it's an analytic inverse-variance fuser; the same `update()`
signature can be backed by a neural model trained on simulation rollouts.
