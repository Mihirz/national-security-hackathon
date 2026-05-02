class_name PressureSensor
extends SensorBase

# Detects the bow-shock pressure wave trailing a hypersonic object.
# Omnidirectional but shorter effective range than IR.
@export var sensitivity: float = 1.0

func _ready() -> void:
	super._ready()
	sensor_type = SensorType.PRESSURE
	max_range = 350.0
	noise_level = 0.07

func get_detection_probability(target: Node3D) -> float:
	if not target or not _owner_uav:
		return 0.0

	var distance: float = _owner_uav.global_position.distance_to(target.global_position)
	# Effective pressure sensing range is shorter
	var effective_range: float = max_range * 0.65
	if distance > effective_range:
		return 0.0

	# Linear falloff; pressure wave is omnidirectional so no angle penalty.
	var range_factor: float = 1.0 - (distance / effective_range)
	var mach_factor: float = 0.88  # hypersonic Mach cone creates strong differential

	return _add_noise(range_factor * mach_factor * sensitivity)
