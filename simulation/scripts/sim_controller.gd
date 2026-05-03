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
var swir: SensorSWIR
var eo: SensorEO
var fusion: SensorFusion
var power: PowerManager
const MLBridgeScript = preload("res://scripts/ml_bridge.gd")
var ml_bridge: Node

@export var enable_ml_bridge: bool = false
@export var ml_query_period_s: float = 0.2
var _ml_query_accum: float = 0.0

var truth_marker: Node3D
var estimate_marker: Node3D
var bearing_lines: Node3D

var _show_truth: bool = false
var _camera_mode: int = 0   # 0 = orbit, 1 = chase ARGUS, 2 = chase HCM

var sim_time_s: float = 0.0

func _ready() -> void:
	argus = get_node(argus_path) as ArgusDrone
	hcm   = get_node(hcm_path) as HCMTarget
	hud   = get_node(hud_path) as Control
	truth_marker = get_node(truth_marker_path) as Node3D
	estimate_marker = get_node(estimate_marker_path) as Node3D
	bearing_lines = get_node(bearing_lines_path) as Node3D

	infrasound = SensorInfrasound.new()
	swir = SensorSWIR.new()
	eo = SensorEO.new()
	fusion = SensorFusion.new()
	power = PowerManager.new()
	add_child(infrasound)
	add_child(swir)
	add_child(eo)
	add_child(fusion)
	add_child(power)
	power.bind(infrasound, swir, eo)

	if enable_ml_bridge:
		ml_bridge = MLBridgeScript.new()
		add_child(ml_bridge)

	if hud and hud.has_method("bind"):
		hud.call("bind", self)

func _physics_process(delta: float) -> void:
	sim_time_s += delta

	var argus_pos := argus.truth_position_m
	var hcm_pos := hcm.truth_position_m
	var hcm_speed := hcm.velocity_mps.length()

	# Sensors sample.
	infrasound.sample(argus_pos, hcm_pos, hcm_speed, delta)
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
			ml_bridge.query(infrasound, swir, eo)

	_update_markers()
	_handle_input()

func _update_markers() -> void:
	if truth_marker:
		truth_marker.visible = _show_truth
		truth_marker.position = hcm.truth_position_m / SimConstants.RENDER_SCALE
	if estimate_marker:
		estimate_marker.visible = fusion.has_estimate
		if fusion.has_estimate:
			estimate_marker.position = fusion.estimated_position_m / SimConstants.RENDER_SCALE

func _handle_input() -> void:
	if Input.is_action_just_pressed("reset_sim"):
		hcm.reset_track()
		fusion.reset()
	if Input.is_action_just_pressed("toggle_truth"):
		_show_truth = not _show_truth
	if Input.is_action_just_pressed("camera_cycle"):
		_camera_mode = (_camera_mode + 1) % 3

func camera_mode() -> int:
	return _camera_mode

func error_m() -> float:
	if not fusion.has_estimate: return -1.0
	return (fusion.estimated_position_m - hcm.truth_position_m).length()
