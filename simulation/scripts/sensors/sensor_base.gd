class_name SensorBase
extends Node

enum SensorType { IR, OPTICAL, PRESSURE }

@export var sensor_type: SensorType
@export var max_range: float = 500.0
@export var noise_level: float = 0.05

var _owner_uav: Node3D = null

func _ready() -> void:
	_owner_uav = get_parent()

# Returns detection probability [0.0, 1.0] for a given target.
func get_detection_probability(_target: Node3D) -> float:
	return 0.0

func _add_noise(value: float) -> float:
	return clamp(value + randf_range(-noise_level, noise_level), 0.0, 1.0)
