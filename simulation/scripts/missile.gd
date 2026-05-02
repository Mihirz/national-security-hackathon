class_name HypersonicMissile
extends Node3D

enum TrajectoryMode {
	STRAIGHT,          # Constant heading, no evasion
	TERRAIN_FOLLOWING, # Altitude oscillation to reduce radar/IR profile
	EVASIVE,           # Lateral + vertical jinking
}

# Speed is scene-units/s; tune this relative to sim scale.
@export var speed: float = 180.0
@export var trajectory_mode: TrajectoryMode = TrajectoryMode.STRAIGHT
@export var avoidance_amplitude: float = 18.0
@export var avoidance_frequency: float = 0.4

var _elapsed: float = 0.0
var _start_position: Vector3
var _direction: Vector3 = Vector3(1, 0, 0)
var _active: bool = false
var _trail_points: Array[Vector3] = []

signal missile_detected(confidence: float)
signal missile_exited_area()

func _ready() -> void:
	_start_position = global_position

func launch(direction: Vector3 = Vector3(1, 0, 0)) -> void:
	_direction = direction.normalized()
	_active = true
	_elapsed = 0.0

func reset() -> void:
	global_position = _start_position
	_active = false
	_elapsed = 0.0

func record_detection(confidence: float) -> void:
	if confidence >= DataFusion.DETECTION_THRESHOLD:
		missile_detected.emit(confidence)

func _physics_process(delta: float) -> void:
	if not _active:
		return
	_elapsed += delta
	_apply_trajectory(delta)

	# Signal once missile exits scene bounds
	if global_position.x > 800.0:
		_active = false
		missile_exited_area.emit()

func _apply_trajectory(delta: float) -> void:
	var velocity: Vector3 = _direction * speed

	match trajectory_mode:
		TrajectoryMode.TERRAIN_FOLLOWING:
			# Sinusoidal altitude change to exploit terrain masking
			var target_y: float = _start_position.y + sin(_elapsed * avoidance_frequency) * avoidance_amplitude
			velocity.y = (target_y - global_position.y) * 4.0

		TrajectoryMode.EVASIVE:
			# Combined vertical and lateral jinking — unpredictable phase offsets
			velocity.y += sin(_elapsed * avoidance_frequency * 2.1) * avoidance_amplitude * 0.8
			velocity.z += cos(_elapsed * avoidance_frequency * 1.7) * avoidance_amplitude * 0.6

	global_position += velocity * delta

	# Keep missile facing direction of travel
	if velocity.length_squared() > 0.01:
		var look_target: Vector3 = global_position + velocity.normalized()
		look_at(look_target, Vector3.UP)
