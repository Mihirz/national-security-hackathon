extends Node3D
class_name ArgusDrone

# ---------------------------------------------------------------------------
# ARGUS solar-glider platform.
#
# Per PDF: "high-aspect-ratio, solar-glider configuration optimized for the
# stratosphere" loitering at 60–90 kft. This is a passive platform — it does
# not chase the HCM at hypersonic speeds; it maintains a persistent overhead
# vantage and feeds the sensor stack. Multi-day endurance is implied by the
# loiter (turn radius is wide, throttle is constant).
# ---------------------------------------------------------------------------

@export var loiter_radius_m: float = 12000.0
@export var loiter_alt_m: float = 24000.0   # mid-band of 60–90 kft
@export var cruise_speed_mps: float = SimConstants.ARGUS_CRUISE_MPS

var truth_position_m: Vector3 = Vector3.ZERO
var velocity_mps: Vector3 = Vector3.ZERO
var heading_rad: float = 0.0
var _phase: float = 0.0

func _ready() -> void:
	loiter_alt_m = clamp(loiter_alt_m, SimConstants.ARGUS_ALT_MIN_M, SimConstants.ARGUS_ALT_MAX_M)
	_recompute(0.0)

func _physics_process(delta: float) -> void:
	# Constant-rate loiter circle. Angular rate set so tangential speed equals
	# cruise_speed_mps, modeling steady-state solar-electric cruise.
	var omega: float = cruise_speed_mps / loiter_radius_m
	_phase += omega * delta
	_recompute(delta)

func _recompute(delta: float) -> void:
	var x: float = cos(_phase) * loiter_radius_m
	var z: float = sin(_phase) * loiter_radius_m
	var new_pos := Vector3(x, loiter_alt_m, z)
	if delta > 0.0:
		velocity_mps = (new_pos - truth_position_m) / delta
	truth_position_m = new_pos
	if velocity_mps.length() > 0.1:
		heading_rad = atan2(velocity_mps.z, velocity_mps.x)

	position = truth_position_m / SimConstants.RENDER_SCALE
	# Face along velocity for a clean visual.
	if velocity_mps.length() > 0.1:
		look_at(position + velocity_mps.normalized(), Vector3.UP)
