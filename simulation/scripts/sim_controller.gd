extends Node3D
class_name SimController

# ---------------------------------------------------------------------------
# Top-level orchestrator. Owns the sensor stack, the power manager, the
# fusion estimator, and ticks them every physics frame using the truth
# state from the ARGUS drone and the HCM target.
# ---------------------------------------------------------------------------

@export var argus_path: NodePath
@export var hcm_path: NodePath
@export var hud_path: NodePath
@export var truth_marker_path: NodePath
@export var estimate_marker_path: NodePath
@export var bearing_lines_path: NodePath

var argus: ArgusDrone
var hcm: HCMTarget
var hud: Control

var infrasound: SensorInfrasound
var pressure: Node   # SensorPressure (preloaded)
var swir: SensorSWIR
var eo: SensorEO
var fusion: SensorFusion
var power: PowerManager
const MLBridgeScript = preload("res://scripts/ml_bridge.gd")
const SensorPressureScript = preload("res://scripts/sensor_pressure.gd")
var ml_bridge: Node

@export var enable_ml_bridge: bool = true
@export var ml_query_period_s: float = 0.1
var _ml_query_accum: float = 0.0

var truth_marker: Node3D
var estimate_marker: Node3D
var bearing_lines: Node3D

var _show_truth: bool = false
var _camera_mode: int = 0   # 0 = orbit, 1 = chase ARGUS, 2 = chase HCM

var sim_time_s: float = 0.0

# ---------------------------------------------------------------------------
# Synthetic prediction (truth + smoothed Ornstein-Uhlenbeck noise).
# Drives the cyan vector arrow + tacmap polyline so the visual is robust
# regardless of model accuracy. Updated each physics tick.
# ---------------------------------------------------------------------------
@export var pred_pos_sigma_m: float = 220.0       # per-tick perturbation scale
@export var pred_pos_decay: float = 0.94          # OU memory (higher = slower drift)
@export var pred_yaw_sigma_rad: float = 0.012     # heading wobble per-tick
@export var pred_yaw_decay: float = 0.96
@export var pred_horizon: int = 10
@export var pred_dt_s: float = 1.0

var predicted_pos_world: Vector3 = Vector3.ZERO
var predicted_vel_world: Vector3 = Vector3.ZERO
var predicted_trajectory: Array[Vector3] = []   # ARGUS-relative future positions
var _ou_pos: Vector3 = Vector3.ZERO
var _ou_yaw: float = 0.0
var _pred_rng := RandomNumberGenerator.new()

func _ready() -> void:
	argus = get_node(argus_path) as ArgusDrone
	hcm   = get_node(hcm_path) as HCMTarget
	hud   = get_node(hud_path) as Control
	truth_marker = get_node(truth_marker_path) as Node3D
	estimate_marker = get_node(estimate_marker_path) as Node3D
	bearing_lines = get_node(bearing_lines_path) as Node3D

	infrasound = SensorInfrasound.new()
	pressure = SensorPressureScript.new()
	swir = SensorSWIR.new()
	eo = SensorEO.new()
	fusion = SensorFusion.new()
	power = PowerManager.new()
	add_child(infrasound)
	add_child(pressure)
	add_child(swir)
	add_child(eo)
	add_child(fusion)
	add_child(power)
	power.bind(infrasound, swir, eo)

	if enable_ml_bridge:
		ml_bridge = MLBridgeScript.new()
		add_child(ml_bridge)

	_pred_rng.randomize()

	if hud and hud.has_method("bind"):
		hud.call("bind", self)

func _physics_process(delta: float) -> void:
	sim_time_s += delta

	var argus_pos := argus.truth_position_m
	var hcm_pos := hcm.truth_position_m
	var hcm_speed := hcm.velocity_mps.length()

	# Sensors sample.
	infrasound.sample(argus_pos, hcm_pos, hcm_speed, delta)
	pressure.sample(argus_pos, argus.heading_rad, hcm_pos, hcm_speed, delta)
	swir.sample(argus_pos, hcm_pos, hcm.thermal_signature, delta)
	eo.sample(argus_pos, hcm_pos, delta)

	# Fusion estimate.
	fusion.update(argus_pos, infrasound, swir, eo, hcm.plasma_blackout, delta)

	# Power tier update (hysteresis-aware).
	power.update(fusion.confidence, delta)

	if ml_bridge:
		_ml_query_accum += delta
		if _ml_query_accum >= ml_query_period_s:
			_ml_query_accum = 0.0
			ml_bridge.query(infrasound, pressure, swir, eo)

	# _step_prediction(delta)  # synthetic OU prediction — deactivated; kept for comparison
	_update_markers()
	_handle_input()

func _step_prediction(_dt: float) -> void:
	# Ornstein-Uhlenbeck noise on top of truth: smoothly drifting offset.
	_ou_pos = _ou_pos * pred_pos_decay + Vector3(
		_pred_rng.randfn(0.0, 1.0),
		_pred_rng.randfn(0.0, 0.35),
		_pred_rng.randfn(0.0, 1.0)
	) * pred_pos_sigma_m * sqrt(1.0 - pred_pos_decay * pred_pos_decay)
	_ou_yaw = _ou_yaw * pred_yaw_decay + _pred_rng.randfn(0.0, 1.0) * pred_yaw_sigma_rad * sqrt(1.0 - pred_yaw_decay * pred_yaw_decay)

	predicted_pos_world = hcm.truth_position_m + _ou_pos
	# Apply a small yaw rotation to the truth velocity to wobble heading.
	var v: Vector3 = hcm.velocity_mps
	var c: float = cos(_ou_yaw)
	var s: float = sin(_ou_yaw)
	predicted_vel_world = Vector3(c * v.x - s * v.z, v.y, s * v.x + c * v.z)

	# Synthetic 10-step future trajectory in ARGUS-relative meters.
	predicted_trajectory.clear()
	var p: Vector3 = predicted_pos_world
	for i in pred_horizon:
		p = p + predicted_vel_world * pred_dt_s
		predicted_trajectory.append(p - argus.truth_position_m)


func _update_markers() -> void:
	if truth_marker:
		truth_marker.visible = _show_truth
		truth_marker.position = hcm.truth_position_m / SimConstants.RENDER_SCALE
	if estimate_marker:
		# Show ML bridge predicted position (first trajectory waypoint).
		# Falls back to hidden when no prediction is available yet.
		var bridge := ml_bridge as MLBridge
		var has_ml := bridge != null and bridge.last_trajectory_pos.size() > 0
		estimate_marker.visible = has_ml
		if has_ml:
			var ml_world := argus.truth_position_m + bridge.last_trajectory_pos[0]
			estimate_marker.global_position = ml_world / SimConstants.RENDER_SCALE
			if bridge.last_trajectory_vel.size() > 0:
				var vel := bridge.last_trajectory_vel[0]
				if vel.length() > 1.0:
					estimate_marker.look_at(estimate_marker.global_position + vel.normalized(), Vector3.UP)

func _handle_input() -> void:
	if Input.is_action_just_pressed("reset_sim"):
		hcm.reset_track()
		fusion.reset()
	if Input.is_action_just_pressed("toggle_truth"):
		_show_truth = not _show_truth


func camera_mode() -> int:
	return _camera_mode

func error_m() -> float:
	if not fusion.has_estimate: return -1.0
	return (fusion.estimated_position_m - hcm.truth_position_m).length()
