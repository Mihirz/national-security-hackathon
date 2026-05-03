extends Node3D
class_name HCMTarget

# ---------------------------------------------------------------------------
# Hypersonic Cruise Missile (HCM) target.
#
# Evasion state machine with five modes:
#   CRUISE      – gentle lateral drift, low G, baseline thermal / blackout.
#   S_TURN      – sinusoidal snake (defeats predictive tracking).
#   JINK        – rapid alternating high-G breaks (3-6 reversals).
#   DIVE        – aggressive nose-down; hugs the lower altitude band.
#   CLIMB_DASH  – brief zoom to ceiling; repositions the detection geometry.
#
# Plasma sheathing (RF blackout) engages whenever sustained G-load pushes
# the lateral bias above the threshold — naturally more frequent during
# JINK and S_TURN phases.
# ---------------------------------------------------------------------------

@export var cruise_speed_mps: float = SimConstants.HCM_CRUISE_MPS
@export var alt_band: Vector2 = Vector2(SimConstants.HCM_ALT_MIN_M, SimConstants.HCM_ALT_MAX_M)
@export var lateral_g: float = 6.0          # base G — modes scale off this
@export var maneuver_period_s: float = 4.5  # legacy export; kept for scene compat
@export var altitude_jitter_m: float = 1500.0  # legacy export; kept for scene compat

enum Maneuver { CRUISE, S_TURN, JINK, DIVE, CLIMB_DASH }

var velocity_mps: Vector3 = Vector3.ZERO
var truth_position_m: Vector3 = Vector3.ZERO
var heading_rad: float = 0.0

var _maneuver: int = Maneuver.CRUISE
var _maneuver_timer: float = 0.0
var _lateral_bias: float = 0.0
var _target_alt_m: float = 22000.0

# S_TURN state
var _s_phase: float = 0.0
var _s_freq: float = 0.5   # rad/s  → ~12 s period
var _s_amp: float  = 1.0

# JINK state
var _jink_subtimer: float = 0.0
var _jink_remaining: int  = 0

var rng := RandomNumberGenerator.new()

# Observable signatures
var plasma_blackout: bool   = false
var thermal_signature: float = 1.0

# ---------------------------------------------------------------------------

func _ready() -> void:
	rng.randomize()
	reset_track()

func reset_track() -> void:
	var start_dist := 80000.0
	var bearing    := rng.randf_range(0.0, TAU)
	truth_position_m = Vector3(
		cos(bearing) * start_dist,
		rng.randf_range(alt_band.x, alt_band.y),
		sin(bearing) * start_dist)
	var inbound := -truth_position_m; inbound.y = 0.0
	heading_rad  = atan2(inbound.z, inbound.x) + rng.randf_range(-0.4, 0.4)
	velocity_mps = Vector3(cos(heading_rad), 0.0, sin(heading_rad)) * cruise_speed_mps
	_target_alt_m   = rng.randf_range(alt_band.x, alt_band.y)
	_maneuver       = Maneuver.CRUISE
	_maneuver_timer = 0.0
	_lateral_bias   = 0.0
	_jink_remaining = 0
	plasma_blackout = false

# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_step_evasion(delta)
	_step_kinematics(delta)
	_update_signatures()
	_update_render_transform()

func _step_evasion(delta: float) -> void:
	_maneuver_timer -= delta
	if _maneuver_timer <= 0.0:
		_pick_maneuver()

	match _maneuver:
		Maneuver.CRUISE:
			pass  # bias fixed at pick time

		Maneuver.S_TURN:
			_s_phase    += _s_freq * delta
			_lateral_bias = sin(_s_phase) * _s_amp

		Maneuver.JINK:
			_jink_subtimer -= delta
			if _jink_subtimer <= 0.0:
				if _jink_remaining > 0:
					_lateral_bias   = -_lateral_bias
					_jink_subtimer  = rng.randf_range(0.7, 1.4)
					_jink_remaining -= 1
				else:
					_lateral_bias = 0.0  # coast straight after series ends

		Maneuver.DIVE:
			# Continuously push target altitude toward the floor
			_target_alt_m = move_toward(_target_alt_m, alt_band.x + rng.randf_range(0.0, 2500.0), 400.0 * delta)

		Maneuver.CLIMB_DASH:
			_target_alt_m = move_toward(_target_alt_m, alt_band.y - rng.randf_range(0.0, 2500.0), 300.0 * delta)

	# Turn rate from lateral G-load (coordinated turn model)
	var g_eff := _current_g()
	var accel  := g_eff * 9.81 * _lateral_bias
	heading_rad += (accel / maxf(cruise_speed_mps, 1.0)) * delta

func _pick_maneuver() -> void:
	var r := rng.randf()

	if r < 0.15:
		# CRUISE — quiet, low lateral load, long dwell
		_maneuver     = Maneuver.CRUISE
		_lateral_bias = rng.randf_range(-0.25, 0.25)
		_maneuver_timer = rng.randf_range(4.0, 8.0)

	elif r < 0.40:
		# S_TURN — sinusoidal snake; defeats linear extrapolation
		_maneuver   = Maneuver.S_TURN
		_s_phase    = rng.randf_range(0.0, TAU)
		_s_freq     = rng.randf_range(0.35, 0.75)   # 8–18 s full period
		_s_amp      = rng.randf_range(0.65, 1.0)
		_maneuver_timer = rng.randf_range(8.0, 18.0)  # several full oscillations

	elif r < 0.62:
		# JINK — hard breaks; most disruptive to tracking
		_maneuver       = Maneuver.JINK
		_jink_remaining = rng.randi_range(3, 6)
		_jink_subtimer  = 0.0
		_lateral_bias   = (1.0 if rng.randf() > 0.5 else -1.0) * rng.randf_range(0.8, 1.0)
		_maneuver_timer = rng.randf_range(5.0, 9.0)

	elif r < 0.80:
		# DIVE — nose-down; defeats look-down radar geometry, increases range ambiguity
		_maneuver     = Maneuver.DIVE
		_lateral_bias = rng.randf_range(-0.45, 0.45)
		_target_alt_m = alt_band.x + rng.randf_range(0.0, 3000.0)
		_maneuver_timer = rng.randf_range(6.0, 12.0)

	else:
		# CLIMB_DASH — zoom to ceiling; repositions look-angle for sensors
		_maneuver     = Maneuver.CLIMB_DASH
		_lateral_bias = rng.randf_range(-0.35, 0.35)
		_target_alt_m = alt_band.y - rng.randf_range(0.0, 3000.0)
		_maneuver_timer = rng.randf_range(5.0, 9.0)

func _current_g() -> float:
	match _maneuver:
		Maneuver.CRUISE:     return lateral_g * 0.35
		Maneuver.S_TURN:     return lateral_g * 0.75
		Maneuver.JINK:       return lateral_g * 1.45  # ~8.7 G at default export
		Maneuver.DIVE:       return lateral_g * 0.55
		Maneuver.CLIMB_DASH: return lateral_g * 0.50
	return lateral_g

# ---------------------------------------------------------------------------

func _step_kinematics(delta: float) -> void:
	var horiz := Vector3(cos(heading_rad), 0.0, sin(heading_rad)) * cruise_speed_mps
	var alt_err := _target_alt_m - truth_position_m.y
	# Dives get an aggressive vertical rate; other modes are gentler
	var v_cap: float = 480.0 if _maneuver == Maneuver.DIVE else 200.0
	var vy: float    = clamp(alt_err * 0.22, -v_cap, v_cap)
	velocity_mps      = Vector3(horiz.x, vy, horiz.z)
	truth_position_m += velocity_mps * delta

	if truth_position_m.length() > 120000.0:
		reset_track()

func _update_signatures() -> void:
	# Plasma blackout: high speed + sustained lateral load (matches original logic)
	plasma_blackout  = (cruise_speed_mps > 1500.0) and (absf(_lateral_bias) > 0.55)
	thermal_signature = pow(cruise_speed_mps / SimConstants.HCM_CRUISE_MPS, 3.0)

func _update_render_transform() -> void:
	position = truth_position_m / SimConstants.RENDER_SCALE
	look_at(position + velocity_mps.normalized(), Vector3.UP)
