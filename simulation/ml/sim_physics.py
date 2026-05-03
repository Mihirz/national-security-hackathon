"""Pure-Python mirror of the Godot sensor physics.

Used by gen_dataset.py to roll out engagements offline. Kept dependency-free
(numpy only) so it stays fast on an M1 CPU.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

# ---- constants ported from sim_constants.gd ----
ARGUS_ALT_MIN_M = 60000.0 * 0.3048
ARGUS_ALT_MAX_M = 90000.0 * 0.3048
HCM_ALT_MIN_M = 18000.0
HCM_ALT_MAX_M = 25000.0
ARGUS_CRUISE_MPS = 28.0
HCM_CRUISE_MPS = 1700.0
INFRASOUND_RANGE_M = 220000.0
SWIR_RANGE_M = 90000.0
EO_RANGE_M = 45000.0


@dataclass
class SensorReading:
    # raw sensor outputs (what the model sees)
    inf_anomaly: float
    inf_bearing_rad: float
    inf_elevation_rad: float
    swir_intensity: float
    swir_bearing_rad: float
    swir_elevation_rad: float
    swir_range_m: float
    swir_lock: float        # 0/1
    eo_class_conf: float
    eo_bearing_rad: float
    eo_elevation_rad: float
    eo_range_m: float
    eo_visual: float        # 0/1
    plasma_blackout: float  # 0/1 (latent context, not always available)
    # ground truth (labels)
    is_target: int
    target_range_m: float
    target_speed_mps: float
    target_alt_m: float
    # ARGUS-relative target position in meters (truth) — used to build
    # trajectory-prediction labels for the transformer.
    rel_x_m: float
    rel_y_m: float
    rel_z_m: float


def _gauss(rng: np.random.Generator, sigma: float) -> float:
    return float(rng.normal(0.0, sigma))


def sample_infrasound(rng, argus_pos, target_pos, target_speed):
    rel = target_pos - argus_pos
    dist = float(np.linalg.norm(rel))
    range_factor = max(0.0, 1.0 - dist / INFRASOUND_RANGE_M)
    shock = (max(target_speed, 1.0) / 340.0) ** 2
    raw = range_factor * (shock / (1.0 + shock)) * 1.6 + _gauss(rng, 0.06)
    anomaly = max(0.0, min(1.0, raw))
    if anomaly < 0.05:
        anomaly = 0.0
    bearing = math.atan2(rel[2], rel[0]) + _gauss(rng, math.radians(8.0))
    horiz = math.hypot(rel[0], rel[2])
    elev = math.atan2(rel[1], max(horiz, 1.0)) + _gauss(rng, math.radians(15.0))
    return anomaly, bearing, elev


def sample_swir(rng, argus_pos, target_pos, target_thermal):
    rel = target_pos - argus_pos
    dist = float(np.linalg.norm(rel))
    if dist > SWIR_RANGE_M:
        return 0.0, 0.0, 0.0, 0.0, 0.0
    apparent = target_thermal / (max(dist / 10000.0, 0.5) ** 2)
    intensity = max(0.0, min(1.0, apparent + _gauss(rng, 0.04)))
    lock = 1.0 if intensity > 0.18 else 0.0
    bearing = math.atan2(rel[2], rel[0]) + _gauss(rng, math.radians(0.8))
    horiz = math.hypot(rel[0], rel[2])
    elev = math.atan2(rel[1], max(horiz, 1.0)) + _gauss(rng, math.radians(0.8))
    if lock and target_thermal > 0.01:
        inv_range = math.sqrt(target_thermal / max(intensity, 1e-3)) * 10000.0
        rng_est = inv_range * (1.0 + _gauss(rng, 0.18))
    else:
        rng_est = 0.0
    return intensity, bearing, elev, rng_est, lock


def sample_eo(rng, argus_pos, target_pos, night_factor=1.0):
    rel = target_pos - argus_pos
    dist = float(np.linalg.norm(rel))
    if dist > EO_RANGE_M:
        return 0.0, 0.0, 0.0, 0.0, 0.0
    vis = (1.0 - dist / EO_RANGE_M) * night_factor
    conf = max(0.0, min(1.0, vis + _gauss(rng, 0.05)))
    visual = 1.0 if conf > 0.25 else 0.0
    bearing = math.atan2(rel[2], rel[0]) + _gauss(rng, math.radians(0.15))
    horiz = math.hypot(rel[0], rel[2])
    elev = math.atan2(rel[1], max(horiz, 1.0)) + _gauss(rng, math.radians(0.15))
    rng_est = dist * (1.0 + _gauss(rng, 0.08)) * (1.0 + _gauss(rng, 0.12 + dist / EO_RANGE_M * 0.2))
    if not visual:
        rng_est = 0.0
    return conf, bearing, elev, rng_est, visual


def roll_engagement(rng: np.random.Generator, n_steps: int = 200, dt: float = 0.1):
    """One ARGUS-vs-HCM scenario; yields per-tick SensorReading rows."""
    # ARGUS loiter
    argus_alt = rng.uniform(ARGUS_ALT_MIN_M, ARGUS_ALT_MAX_M)
    argus_radius = rng.uniform(8000.0, 14000.0)
    argus_phase = rng.uniform(0.0, 2 * math.pi)

    # HCM start
    is_target = rng.random() < 0.75  # 25% are noise/no-target scenarios
    if is_target:
        start_dist = rng.uniform(60000.0, 110000.0)
        bearing = rng.uniform(0.0, 2 * math.pi)
        target_pos = np.array([
            math.cos(bearing) * start_dist,
            rng.uniform(HCM_ALT_MIN_M, HCM_ALT_MAX_M),
            math.sin(bearing) * start_dist,
        ])
        heading = math.atan2(-target_pos[2], -target_pos[0]) + rng.uniform(-0.4, 0.4)
        speed = rng.uniform(1200.0, 2200.0)
        velocity = np.array([math.cos(heading) * speed, 0.0, math.sin(heading) * speed])
        target_alt_setpoint = rng.uniform(HCM_ALT_MIN_M, HCM_ALT_MAX_M)
    else:
        # Decoy: slow, distant, weak thermal — what the model should NOT lock onto.
        start_dist = rng.uniform(30000.0, 200000.0)
        bearing = rng.uniform(0.0, 2 * math.pi)
        target_pos = np.array([
            math.cos(bearing) * start_dist,
            rng.uniform(8000.0, 30000.0),
            math.sin(bearing) * start_dist,
        ])
        speed = rng.uniform(80.0, 320.0)
        heading = rng.uniform(0.0, 2 * math.pi)
        velocity = np.array([math.cos(heading) * speed, 0.0, math.sin(heading) * speed])
        target_alt_setpoint = target_pos[1]

    rows = []
    for step in range(n_steps):
        argus_phase += (ARGUS_CRUISE_MPS / argus_radius) * dt
        argus_pos = np.array([
            math.cos(argus_phase) * argus_radius,
            argus_alt,
            math.sin(argus_phase) * argus_radius,
        ])

        # propagate target with light evasion
        if is_target and step % 45 == 0:
            heading += rng.uniform(-0.6, 0.6)
            target_alt_setpoint = float(np.clip(
                target_alt_setpoint + rng.uniform(-1500, 1500),
                HCM_ALT_MIN_M, HCM_ALT_MAX_M))
        velocity[0] = math.cos(heading) * speed
        velocity[2] = math.sin(heading) * speed
        velocity[1] = float(np.clip((target_alt_setpoint - target_pos[1]) * 0.15, -180, 180))
        target_pos = target_pos + velocity * dt

        # signatures
        if is_target:
            thermal = (speed / HCM_CRUISE_MPS) ** 3
            blackout = 1.0 if (speed > 1500.0 and rng.random() < 0.25) else 0.0
        else:
            thermal = rng.uniform(0.02, 0.15)  # background sources / weak emitter
            blackout = 0.0

        anom, ib, ie = sample_infrasound(rng, argus_pos, target_pos, speed)
        si, sb, se, srng, slock = sample_swir(rng, argus_pos, target_pos, thermal)
        ec, eb, ee, erng, evis = sample_eo(rng, argus_pos, target_pos)

        rel = target_pos - argus_pos
        rows.append(SensorReading(
            inf_anomaly=anom, inf_bearing_rad=ib, inf_elevation_rad=ie,
            swir_intensity=si, swir_bearing_rad=sb, swir_elevation_rad=se,
            swir_range_m=srng, swir_lock=slock,
            eo_class_conf=ec, eo_bearing_rad=eb, eo_elevation_rad=ee,
            eo_range_m=erng, eo_visual=evis,
            plasma_blackout=blackout,
            is_target=int(is_target),
            target_range_m=float(np.linalg.norm(rel)),
            target_speed_mps=float(speed),
            target_alt_m=float(target_pos[1]),
            rel_x_m=float(rel[0]),
            rel_y_m=float(rel[1]),
            rel_z_m=float(rel[2]),
        ))
    return rows


FEATURE_NAMES = [
    "inf_anomaly", "inf_bearing_sin", "inf_bearing_cos", "inf_elev",
    "swir_intensity", "swir_bearing_sin", "swir_bearing_cos", "swir_elev",
    "swir_range_norm", "swir_lock",
    "eo_class_conf", "eo_bearing_sin", "eo_bearing_cos", "eo_elev",
    "eo_range_norm", "eo_visual",
]


def reading_to_features(r: SensorReading) -> np.ndarray:
    return np.array([
        r.inf_anomaly,
        math.sin(r.inf_bearing_rad), math.cos(r.inf_bearing_rad),
        r.inf_elevation_rad,
        r.swir_intensity,
        math.sin(r.swir_bearing_rad), math.cos(r.swir_bearing_rad),
        r.swir_elevation_rad,
        r.swir_range_m / 100000.0,
        r.swir_lock,
        r.eo_class_conf,
        math.sin(r.eo_bearing_rad), math.cos(r.eo_bearing_rad),
        r.eo_elevation_rad,
        r.eo_range_m / 100000.0,
        r.eo_visual,
    ], dtype=np.float32)


def reading_to_labels(r: SensorReading) -> np.ndarray:
    return np.array([
        float(r.is_target),
        r.target_range_m / 100000.0,
        r.target_speed_mps / 2500.0,
    ], dtype=np.float32)
