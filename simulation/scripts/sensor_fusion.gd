extends Node
class_name SensorFusion

# ---------------------------------------------------------------------------
# Multi-modal sensor fusion estimator.
#
# Per PDF: "agents do not receive exact target coordinates; instead, they
# must fuse simulated inputs from their onboard IR, optical cameras, and
# atmospheric pressure sensors to estimate the target's state."
#
# This is an inverse-variance bearing fusion + range-from-modality
# weighting, plus a constant-velocity tracker over the fused position.
# It deliberately does NOT touch the HCM's truth_position_m — only the
# noisy sensor outputs. This is the "brain" surface from the PDF.
# ---------------------------------------------------------------------------

# Estimated state (in world meters, ARGUS-relative for direction).
var estimated_position_m: Vector3 = Vector3.ZERO
var estimated_velocity_mps: Vector3 = Vector3.ZERO
var confidence: float = 0.0           # 0..1
var has_estimate: bool = false

# Per-sensor variance priors (smaller = trusted more).
const VAR_INFRASOUND_BEARING: float = 0.018   # ~7.7°^2
const VAR_SWIR_BEARING: float = 0.00020       # ~0.8°^2
const VAR_EO_BEARING: float = 0.0000068       # ~0.15°^2

const VAR_SWIR_RANGE_REL: float = 0.18
const VAR_EO_RANGE_REL: float = 0.20

var _last_estimate_m: Vector3 = Vector3.ZERO
var _have_prev: bool = false
var _alpha_pos: float = 0.35   # EMA smoothing on position
var _alpha_vel: float = 0.25

func update(argus_pos_m: Vector3,
			i: SensorInfrasound,
			s: SensorSWIR,
			e: SensorEO,
			plasma_blackout: bool,
			dt: float) -> void:

	# 1) Bearing fusion via inverse-variance weighting.
	var bearings: Array[float] = []
	var elevations: Array[float] = []
	var weights: Array[float] = []

	if i.is_powered and i.anomaly_score > 0.05:
		bearings.append(i.bearing_rad)
		elevations.append(i.elevation_rad)
		weights.append(1.0 / VAR_INFRASOUND_BEARING * i.anomaly_score)

	if s.is_powered and s.has_lock:
		bearings.append(s.bearing_rad)
		elevations.append(s.elevation_rad)
		weights.append(1.0 / VAR_SWIR_BEARING * s.thermal_intensity)

	if e.is_powered and e.has_visual:
		bearings.append(e.bearing_rad)
		elevations.append(e.elevation_rad)
		weights.append(1.0 / VAR_EO_BEARING * e.classification_conf)

	if bearings.is_empty():
		# Coast: predict forward from last velocity, decay confidence.
		confidence = max(confidence - dt * 0.5, 0.0)
		if has_estimate:
			estimated_position_m += estimated_velocity_mps * dt
		return

	var fused_bearing: float = _circular_weighted_mean(bearings, weights)
	var fused_elev: float = _weighted_mean(elevations, weights)

	# 2) Range fusion. Infrasound gives no range; SWIR/EO give noisy range.
	var range_sum := 0.0
	var range_w := 0.0
	if s.is_powered and s.has_lock and s.range_estimate_m > 0.0:
		var w_s: float = 1.0 / pow(VAR_SWIR_RANGE_REL * s.range_estimate_m, 2.0)
		range_sum += s.range_estimate_m * w_s
		range_w += w_s
	if e.is_powered and e.has_visual and e.range_estimate_m > 0.0:
		var w_e: float = 1.0 / pow(VAR_EO_RANGE_REL * e.range_estimate_m, 2.0)
		range_sum += e.range_estimate_m * w_e
		range_w += w_e

	var range_estimate := 0.0
	if range_w > 0.0:
		range_estimate = range_sum / range_w
	else:
		# Bearings-only mode (typical during blackout/early DETECT). Fall
		# back to last known range, slowly drifting outward (uncertainty).
		if has_estimate:
			range_estimate = (estimated_position_m - argus_pos_m).length() * (1.0 + dt * 0.05)
		else:
			range_estimate = SimConstants.SWIR_RANGE_M * 0.5

	# 3) Reconstruct estimated position from bearing + elevation + range.
	var dir: Vector3 = Vector3(cos(fused_bearing) * cos(fused_elev),
					   sin(fused_elev),
					   sin(fused_bearing) * cos(fused_elev))
	var raw_pos: Vector3 = argus_pos_m + dir * range_estimate

	if not has_estimate:
		estimated_position_m = raw_pos
		_last_estimate_m = raw_pos
		has_estimate = true
	else:
		estimated_position_m = estimated_position_m.lerp(raw_pos, _alpha_pos)
		var inst_v: Vector3 = (estimated_position_m - _last_estimate_m) / max(dt, 1e-3)
		estimated_velocity_mps = estimated_velocity_mps.lerp(inst_v, _alpha_vel)
		_last_estimate_m = estimated_position_m

	# 4) Confidence: combine modality count, individual confidences, and a
	# blackout-tolerance bonus when IR/acoustic agree (the PDF's whole point).
	var c: float = 0.0
	if i.anomaly_score > 0.05: c += 0.20 * i.anomaly_score
	if s.has_lock:             c += 0.40 * s.thermal_intensity
	if e.has_visual:           c += 0.45 * e.classification_conf
	if plasma_blackout and s.has_lock and i.anomaly_score > 0.1:
		c += 0.10   # blackout-resilient cross-modal confirmation
	confidence = clamp(c, 0.0, 1.0)

func _weighted_mean(values: Array[float], weights: Array[float]) -> float:
	var s: float = 0.0
	var w: float = 0.0
	for idx in values.size():
		s += values[idx] * weights[idx]
		w += weights[idx]
	if w == 0.0: return 0.0
	return s / w

func _circular_weighted_mean(angles: Array[float], weights: Array[float]) -> float:
	# Average angles via the unit-vector trick to handle wraparound.
	var x: float = 0.0
	var y: float = 0.0
	for idx in angles.size():
		x += cos(angles[idx]) * weights[idx]
		y += sin(angles[idx]) * weights[idx]
	return atan2(y, x)

func reset() -> void:
	estimated_position_m = Vector3.ZERO
	estimated_velocity_mps = Vector3.ZERO
	confidence = 0.0
	has_estimate = false
	_have_prev = false
