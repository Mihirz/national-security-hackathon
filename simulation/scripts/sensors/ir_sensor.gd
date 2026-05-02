class_name IRSensor
extends SensorBase

# Hypersonic friction generates extreme IR signature — dominant sensor at range.
func _ready() -> void:
	super._ready()
	sensor_type = SensorType.IR
	max_range = 600.0
	noise_level = 0.04

func get_detection_probability(target: Node3D) -> float:
	if not target or not _owner_uav:
		return 0.0

	var distance: float = _owner_uav.global_position.distance_to(target.global_position)
	if distance > max_range:
		return 0.0

	# Square-root falloff: IR persists well at distance due to heat plume.
	var range_factor: float = pow(1.0 - (distance / max_range), 0.5)
	var heat_factor: float = 0.95  # hypersonic aero-heating gives near-maximum signature

	return _add_noise(range_factor * heat_factor)
