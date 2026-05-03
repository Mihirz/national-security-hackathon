extends Node
class_name SensorSWIR

# ---------------------------------------------------------------------------
# Short-Wave Infrared (SWIR) array.
#
# Per PDF: "anomaly triggers the Short-Wave Infrared (SWIR) array for
# thermal verification". SWIR sees the HCM's thermal plume / aerodynamic
# heating skin glow. It returns a thermal-bearing pair with much tighter
# noise than infrasound, plus a coarse range estimate from the apparent
# plume intensity (assuming a calibrated emitter model).
#
# Crucially, SWIR is unaffected by RF blackout (plasma sheathing actually
# *increases* IR signature), making the IR + acoustic combination the core
# of ARGUS's blackout-tolerant tracking.
# ---------------------------------------------------------------------------

@export var bearing_noise_rad: float = deg_to_rad(0.8)
@export var range_noise_frac: float = 0.18
var rng := RandomNumberGenerator.new()

var is_powered: bool = false       # gated by power manager
var thermal_intensity: float = 0.0 # 0..1
var bearing_rad: float = 0.0
var elevation_rad: float = 0.0
var range_estimate_m: float = 0.0
var has_lock: bool = false

func _ready() -> void:
	rng.randomize()

func sample(argus_pos_m: Vector3, target_pos_m: Vector3, target_thermal: float, _dt: float) -> void:
	if not is_powered:
		thermal_intensity = 0.0
		has_lock = false
		return

	var rel := target_pos_m - argus_pos_m
	var dist := rel.length()
	if dist > SimConstants.SWIR_RANGE_M:
		thermal_intensity = 0.0
		has_lock = false
		return

	# Apparent intensity ~ emitted / dist^2. Plasma sheathing boosts the
	# signature (extra IR from ionization). We pass that as target_thermal.
	var emitted := target_thermal
	var apparent: float = emitted / pow(max(dist / 10000.0, 0.5), 2.0)
	thermal_intensity = clamp(apparent + rng.randfn(0.0, 0.04), 0.0, 1.0)
	has_lock = thermal_intensity > 0.18

	# Bearing is high-fidelity for a focal-plane IR array.
	var true_bearing := atan2(rel.z, rel.x)
	bearing_rad = true_bearing + rng.randfn(0.0, bearing_noise_rad)
	var horiz: float = Vector2(rel.x, rel.z).length()
	elevation_rad = atan2(rel.y, max(horiz, 1.0)) + rng.randfn(0.0, bearing_noise_rad)

	# Coarse range from intensity inversion (calibrated emitter model).
	if has_lock and emitted > 0.01:
		var inv_range: float = sqrt(emitted / max(thermal_intensity, 1e-3)) * 10000.0
		range_estimate_m = inv_range * (1.0 + rng.randfn(0.0, range_noise_frac))
	else:
		range_estimate_m = 0.0
