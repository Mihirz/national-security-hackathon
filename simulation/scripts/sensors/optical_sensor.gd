class_name OpticalSensor
extends SensorBase

@export var field_of_view_deg: float = 60.0

func _ready() -> void:
	super._ready()
	sensor_type = SensorType.OPTICAL
	max_range = 400.0
	noise_level = 0.06

func get_detection_probability(target: Node3D) -> float:
	if not target or not _owner_uav:
		return 0.0

	var distance: float = _owner_uav.global_position.distance_to(target.global_position)
	if distance > max_range:
		return 0.0

	var to_target: Vector3 = (target.global_position - _owner_uav.global_position).normalized()
	var uav_forward: Vector3 = -_owner_uav.global_transform.basis.z
	var angle_deg: float = rad_to_deg(to_target.angle_to(uav_forward))

	if angle_deg > field_of_view_deg * 0.5:
		return 0.0

	# Inverse-square falloff clipped by field of view.
	var range_factor: float = pow(1.0 - (distance / max_range), 2.0)
	var angle_factor: float = 1.0 - (angle_deg / (field_of_view_deg * 0.5))

	return _add_noise(range_factor * angle_factor * 0.85)
