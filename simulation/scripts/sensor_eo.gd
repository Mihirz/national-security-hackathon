extends Node
class_name SensorEO

# ---------------------------------------------------------------------------
# Electro-Optical (EO) camera.
#
# Per PDF: third modality alongside IR and pressure/acoustic. Highest
# fidelity bearing measurement once the target is in the EO field of view,
# but limited range (atmospheric scatter) and degraded under cloud cover or
# at night. Provides a confirmed visual classification + tight bearing.
# ---------------------------------------------------------------------------

@export var bearing_noise_rad: float = deg_to_rad(0.15)
@export var night_factor: float = 0.55     # daylight = 1.0
var rng := RandomNumberGenerator.new()

var is_powered: bool = false
var has_visual: bool = false
var classification_conf: float = 0.0
var bearing_rad: float = 0.0
var elevation_rad: float = 0.0
var range_estimate_m: float = 0.0   # parallax / known-size estimate

func _ready() -> void:
	rng.randomize()

func sample(argus_pos_m: Vector3, target_pos_m: Vector3, _dt: float) -> void:
	if not is_powered:
		has_visual = false
		classification_conf = 0.0
		return

	var rel := target_pos_m - argus_pos_m
	var dist := rel.length()
	if dist > SimConstants.EO_RANGE_M:
		has_visual = false
		classification_conf = 0.0
		return

	# Visual confidence rolls off with distance and lighting.
	var vis: float = (1.0 - dist / SimConstants.EO_RANGE_M) * night_factor
	classification_conf = clamp(vis + rng.randfn(0.0, 0.05), 0.0, 1.0)
	has_visual = classification_conf > 0.25

	var true_bearing := atan2(rel.z, rel.x)
	bearing_rad = true_bearing + rng.randfn(0.0, bearing_noise_rad)
	var horiz: float = Vector2(rel.x, rel.z).length()
	elevation_rad = atan2(rel.y, max(horiz, 1.0)) + rng.randfn(0.0, bearing_noise_rad)

	# Range from apparent angular size (HCM body length ~6 m prior).
	# Camera doesn't get range cleanly without parallax — degrade for distance.
	var pixel_jitter: float = 1.0 + rng.randfn(0.0, 0.08)
	range_estimate_m = dist * pixel_jitter * (1.0 + rng.randfn(0.0, 0.12 + dist / SimConstants.EO_RANGE_M * 0.2))
	if not has_visual:
		range_estimate_m = 0.0
