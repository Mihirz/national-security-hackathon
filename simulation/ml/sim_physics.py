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

# ---- 5-mode evasion constants (mirror of hcm_target.gd) ----
LATERAL_G = 6.0
MANEUVER_CRUISE     = 0
MANEUVER_S_TURN     = 1
MANEUVER_JINK       = 2
MANEUVER_DIVE       = 3
MANEUVER_CLIMB_DASH = 4


@dataclass
class SensorReading:
    # raw sensor outputs (what the model sees)
    inf_anomaly: float
    inf_bearing_rad: float
    inf_elevation_rad: float
    pressure_left: float
    pressure_right: float
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
    # ARGUS-relative target position + velocity in meters (truth).
    rel_x_m: float
    rel_y_m: float
    rel_z_m: float
    vel_x_mps: float
    vel_y_mps: float
    vel_z_mps: float


def _gauss(rng: np.random.Generator, sigma: float) -> float:
    return float(rng.normal(0.0, sigma))


def sample_pressure(rng, argus_pos, argus_heading_rad, target_pos, target_speed):
    """Stereo wingtip transducers — sum encodes intensity, difference encodes
    lateral bearing relative to glider body."""
    rel = target_pos - argus_pos
    dist = float(np.linalg.norm(rel))
    range_factor = max(0.0, 1.0 - dist / INFRASOUND_RANGE_M) ** 1.8
    mach = max(target_speed, 1.0) / 340.0
    base = range_factor * (1.0 - math.exp(-(mach * mach) / 90.0))
    rel_az = math.atan2(rel[2], rel[0]) - argus_heading_rad
    lateral = math.sin(rel_az)
    left = base * (0.5 + 0.5 * lateral) + _gauss(rng, 0.025)
    right = base * (0.5 - 0.5 * lateral) + _gauss(rng, 0.025)
    return max(0.0, min(1.5, left)), max(0.0, min(1.5, right))


def sample_infrasound(rng, argus_pos, target_pos, target_speed):
    rel = target_pos - argus_pos
    dist = float(np.linalg.norm(rel))
    range_factor = max(0.0, 1.0 - dist / INFRASOUND_RANGE_M) ** 1.8
    mach = max(target_speed, 1.0) / 340.0
    shock = 1.0 - math.exp(-(mach * mach) / 90.0)
    raw = range_factor * shock + _gauss(rng, 0.04)
    anomaly = max(0.0, min(1.0, raw))
    if anomaly < 0.04:
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


def _g_for_maneuver(maneuver: int) -> float:
    if maneuver == MANEUVER_CRUISE:     return LATERAL_G * 0.35
    if maneuver == MANEUVER_S_TURN:     return LATERAL_G * 0.75
    if maneuver == MANEUVER_JINK:       return LATERAL_G * 1.45
    if maneuver == MANEUVER_DIVE:       return LATERAL_G * 0.55
    if maneuver == MANEUVER_CLIMB_DASH: return LATERAL_G * 0.50
    return LATERAL_G


def _pick_maneuver(rng, alt_min, alt_max):
    """Returns (maneuver_id, state_dict) matching hcm_target.gd _pick_maneuver."""
    r = float(rng.random())
    if r < 0.15:
        return MANEUVER_CRUISE, {
            "lateral_bias":  float(rng.uniform(-0.25, 0.25)),
            "timer":         float(rng.uniform(4.0, 8.0)),
            "target_alt":    None,
        }
    elif r < 0.40:
        return MANEUVER_S_TURN, {
            "lateral_bias": 0.0,
            "s_phase":      float(rng.uniform(0.0, 2 * math.pi)),
            "s_freq":       float(rng.uniform(0.35, 0.75)),
            "s_amp":        float(rng.uniform(0.65, 1.0)),
            "timer":        float(rng.uniform(8.0, 18.0)),
            "target_alt":   None,
        }
    elif r < 0.62:
        sign = 1.0 if rng.random() > 0.5 else -1.0
        return MANEUVER_JINK, {
            "lateral_bias":    sign * float(rng.uniform(0.8, 1.0)),
            "jink_remaining":  int(rng.integers(3, 7)),
            "jink_subtimer":   0.0,
            "timer":           float(rng.uniform(5.0, 9.0)),
            "target_alt":      None,
        }
    elif r < 0.80:
        return MANEUVER_DIVE, {
            "lateral_bias": float(rng.uniform(-0.45, 0.45)),
            "timer":        float(rng.uniform(6.0, 12.0)),
            "target_alt":   float(alt_min + rng.uniform(0.0, 3000.0)),
        }
    else:
        return MANEUVER_CLIMB_DASH, {
            "lateral_bias": float(rng.uniform(-0.35, 0.35)),
            "timer":        float(rng.uniform(5.0, 9.0)),
            "target_alt":   float(alt_max - rng.uniform(0.0, 3000.0)),
        }


def roll_engagement(rng: np.random.Generator, n_steps: int = 200, dt: float = 0.1):
    """One ARGUS-vs-HCM scenario; yields per-tick SensorReading rows."""
    # ARGUS loiter
    argus_alt = rng.uniform(ARGUS_ALT_MIN_M, ARGUS_ALT_MAX_M)
    argus_radius = rng.uniform(8000.0, 14000.0)
    argus_phase = rng.uniform(0.0, 2 * math.pi)

    # HCM start — fixed cruise speed to match Godot sim
    is_target = rng.random() < 0.75
    if is_target:
        start_dist = rng.uniform(60000.0, 110000.0)
        bearing = rng.uniform(0.0, 2 * math.pi)
        speed = HCM_CRUISE_MPS
        target_pos = np.array([
            math.cos(bearing) * start_dist,
            rng.uniform(HCM_ALT_MIN_M, HCM_ALT_MAX_M),
            math.sin(bearing) * start_dist,
        ])
        heading = math.atan2(-target_pos[2], -target_pos[0]) + rng.uniform(-0.4, 0.4)
        velocity = np.array([math.cos(heading) * speed, 0.0, math.sin(heading) * speed])
        target_alt_setpoint = rng.uniform(HCM_ALT_MIN_M, HCM_ALT_MAX_M)

        # 5-mode evasion state (mirrors hcm_target.gd)
        maneuver, mv_state = _pick_maneuver(rng, HCM_ALT_MIN_M, HCM_ALT_MAX_M)
        if mv_state["target_alt"] is not None:
            target_alt_setpoint = mv_state["target_alt"]
    else:
        # Decoy: slow, distant, weak thermal.
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
        target_alt_setpoint = float(target_pos[1])
        maneuver, mv_state = MANEUVER_CRUISE, {"lateral_bias": 0.0, "timer": 1e9, "target_alt": None}

    rows = []
    for _ in range(n_steps):
        argus_phase += (ARGUS_CRUISE_MPS / argus_radius) * dt
        argus_pos = np.array([
            math.cos(argus_phase) * argus_radius,
            argus_alt,
            math.sin(argus_phase) * argus_radius,
        ])
        argus_heading = argus_phase + math.pi / 2.0

        if is_target:
            # ---- evasion timer ----
            mv_state["timer"] -= dt
            if mv_state["timer"] <= 0.0:
                maneuver, mv_state = _pick_maneuver(rng, HCM_ALT_MIN_M, HCM_ALT_MAX_M)
                if mv_state["target_alt"] is not None:
                    target_alt_setpoint = mv_state["target_alt"]

            # ---- per-mode update ----
            if maneuver == MANEUVER_S_TURN:
                mv_state["s_phase"] += mv_state["s_freq"] * dt
                mv_state["lateral_bias"] = math.sin(mv_state["s_phase"]) * mv_state["s_amp"]

            elif maneuver == MANEUVER_JINK:
                mv_state["jink_subtimer"] -= dt
                if mv_state["jink_subtimer"] <= 0.0:
                    if mv_state["jink_remaining"] > 0:
                        mv_state["lateral_bias"]   = -mv_state["lateral_bias"]
                        mv_state["jink_subtimer"]  = float(rng.uniform(0.7, 1.4))
                        mv_state["jink_remaining"] -= 1
                    else:
                        mv_state["lateral_bias"] = 0.0

            elif maneuver == MANEUVER_DIVE:
                # proportional altitude controller toward floor target
                target_alt_setpoint = max(
                    HCM_ALT_MIN_M,
                    target_alt_setpoint - 400.0 * dt * max(0.0, target_alt_setpoint - HCM_ALT_MIN_M) / max(HCM_ALT_MAX_M - HCM_ALT_MIN_M, 1.0)
                )

            elif maneuver == MANEUVER_CLIMB_DASH:
                target_alt_setpoint = min(
                    HCM_ALT_MAX_M,
                    target_alt_setpoint + 300.0 * dt * max(0.0, HCM_ALT_MAX_M - target_alt_setpoint) / max(HCM_ALT_MAX_M - HCM_ALT_MIN_M, 1.0)
                )

            # ---- kinematics (mirror of _step_kinematics) ----
            g_eff = _g_for_maneuver(maneuver)
            accel = g_eff * 9.81 * mv_state["lateral_bias"]
            heading += (accel / max(speed, 1.0)) * dt

            v_cap = 480.0 if maneuver == MANEUVER_DIVE else 200.0
            alt_err = target_alt_setpoint - target_pos[1]
            vy = max(-v_cap, min(v_cap, alt_err * 0.22))
            velocity = np.array([math.cos(heading) * speed, vy, math.sin(heading) * speed])
            target_pos = target_pos + velocity * dt
            target_pos[1] = max(HCM_ALT_MIN_M * 0.5, target_pos[1])  # soft floor

            thermal = (speed / HCM_CRUISE_MPS) ** 3  # = 1.0 at cruise
            blackout = 1.0 if (speed > 1500.0 and abs(mv_state["lateral_bias"]) > 0.55) else 0.0
        else:
            # Decoy: simple straight flight with slow heading drift
            if _ % 60 == 0:
                heading += float(rng.uniform(-0.3, 0.3))
            velocity[0] = math.cos(heading) * speed
            velocity[2] = math.sin(heading) * speed
            velocity[1] = max(-50.0, min(50.0, (target_alt_setpoint - target_pos[1]) * 0.1))
            target_pos = target_pos + velocity * dt
            thermal = rng.uniform(0.02, 0.15)
            blackout = 0.0

        anom, ib, ie = sample_infrasound(rng, argus_pos, target_pos, speed)
        pl, pr = sample_pressure(rng, argus_pos, argus_heading, target_pos, speed)
        si, sb, se, srng, slock = sample_swir(rng, argus_pos, target_pos, thermal)
        ec, eb, ee, erng, evis = sample_eo(rng, argus_pos, target_pos)

        rel = target_pos - argus_pos
        rows.append(SensorReading(
            inf_anomaly=anom, inf_bearing_rad=ib, inf_elevation_rad=ie,
            pressure_left=pl, pressure_right=pr,
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
            vel_x_mps=float(velocity[0]),
            vel_y_mps=float(velocity[1]),
            vel_z_mps=float(velocity[2]),
        ))
    return rows


FEATURE_NAMES = [
    "inf_anomaly", "inf_bearing_sin", "inf_bearing_cos", "inf_elev",
    "pressure_left", "pressure_right",
    "swir_intensity", "swir_bearing_sin", "swir_bearing_cos", "swir_elev",
    "swir_range_norm", "swir_lock",
    "eo_class_conf", "eo_bearing_sin", "eo_bearing_cos", "eo_elev",
    "eo_range_norm", "eo_visual",
]
INPUT_DIM = len(FEATURE_NAMES)  # 18


def reading_to_features(r: SensorReading) -> np.ndarray:
    # Zero out bearing sin/cos when the sensor has no valid reading,
    # matching the ml_bridge.gd fix for stale bearings on no-lock frames.
    swir_sin = math.sin(r.swir_bearing_rad) if r.swir_lock > 0.5 else 0.0
    swir_cos = math.cos(r.swir_bearing_rad) if r.swir_lock > 0.5 else 1.0
    eo_sin   = math.sin(r.eo_bearing_rad)   if r.eo_visual > 0.5 else 0.0
    eo_cos   = math.cos(r.eo_bearing_rad)   if r.eo_visual > 0.5 else 1.0
    return np.array([
        r.inf_anomaly,
        math.sin(r.inf_bearing_rad), math.cos(r.inf_bearing_rad),
        r.inf_elevation_rad,
        r.pressure_left, r.pressure_right,
        r.swir_intensity,
        swir_sin, swir_cos,
        r.swir_elevation_rad,
        r.swir_range_m / 100000.0,
        r.swir_lock,
        r.eo_class_conf,
        eo_sin, eo_cos,
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
