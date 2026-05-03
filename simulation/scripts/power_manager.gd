extends Node
class_name PowerManager

# ---------------------------------------------------------------------------
# Tiered detection / power-gated sensor fusion.
#
# Per PDF: "tiered detection architecture that employs power-gated sensor
# fusion. The system remains in a low-power state using passive infrasound
# monitoring until an anomaly triggers the SWIR array for thermal
# verification. Active satellite uplinks are only engaged during confirmed
# threats to conserve energy."
#
# State machine:
#   IDLE   — only infrasound powered.
#   DETECT — infrasound flagged anomaly; spin up SWIR.
#   TRACK  — SWIR confirms thermal; spin up EO camera.
#   ENGAGE — fusion confidence high; activate satellite uplink.
# ---------------------------------------------------------------------------

enum Tier { IDLE, DETECT, TRACK, ENGAGE }

signal tier_changed(new_tier: int, old_tier: int)

var tier: int = Tier.IDLE
var draw_w: float = SimConstants.POWER_INFRASOUND_W
var energy_used_wh: float = 0.0
var uplink_active: bool = false

# Hysteresis to prevent thrash at threshold boundaries.
var _down_grace_s: float = 0.0
const DOWNGRADE_GRACE: float = 1.5

var infrasound: SensorInfrasound
var swir: SensorSWIR
var eo: SensorEO

func bind(i: SensorInfrasound, s: SensorSWIR, e: SensorEO) -> void:
	infrasound = i
	swir = s
	eo = e
	_apply_tier(Tier.IDLE, true)

func update(fusion_confidence: float, dt: float) -> void:
	# Infrasound is always on.
	infrasound.is_powered = true

	var anomaly := infrasound.anomaly_score
	var thermal_locked := swir.has_lock
	var visual_locked := eo.has_visual

	var desired := tier

	# Promote on rising edges.
	if anomaly >= SimConstants.TIER_DETECT_CONF and tier == Tier.IDLE:
		desired = Tier.DETECT
	if thermal_locked and fusion_confidence >= SimConstants.TIER_TRACK_CONF and tier <= Tier.DETECT:
		desired = Tier.TRACK
	if visual_locked and fusion_confidence >= SimConstants.TIER_ENGAGE_CONF:
		desired = Tier.ENGAGE

	# Demote with hysteresis (DOWNGRADE_GRACE s of low signal before stepping down).
	var should_demote := false
	match tier:
		Tier.ENGAGE:
			if fusion_confidence < SimConstants.TIER_ENGAGE_CONF - 0.1 or not visual_locked:
				should_demote = true
		Tier.TRACK:
			if fusion_confidence < SimConstants.TIER_TRACK_CONF - 0.1 or not thermal_locked:
				should_demote = true
		Tier.DETECT:
			if anomaly < SimConstants.TIER_DETECT_CONF - 0.05:
				should_demote = true

	if should_demote:
		_down_grace_s += dt
		if _down_grace_s >= DOWNGRADE_GRACE:
			desired = max(Tier.IDLE, tier - 1)
			_down_grace_s = 0.0
	else:
		_down_grace_s = 0.0

	if desired != tier:
		_apply_tier(desired, false)

	_accumulate_energy(dt)

func _apply_tier(new_tier: int, force: bool) -> void:
	var old := tier
	tier = new_tier
	swir.is_powered = tier >= Tier.DETECT
	eo.is_powered = tier >= Tier.TRACK
	uplink_active = tier >= Tier.ENGAGE

	draw_w = SimConstants.POWER_INFRASOUND_W
	if swir.is_powered: draw_w += SimConstants.POWER_SWIR_W
	if eo.is_powered:   draw_w += SimConstants.POWER_EO_W
	if uplink_active:   draw_w += SimConstants.POWER_UPLINK_W

	if force or old != new_tier:
		tier_changed.emit(new_tier, old)

func _accumulate_energy(dt: float) -> void:
	energy_used_wh += draw_w * (dt / 3600.0)

func tier_name() -> String:
	match tier:
		Tier.IDLE: return "IDLE"
		Tier.DETECT: return "DETECT"
		Tier.TRACK: return "TRACK"
		Tier.ENGAGE: return "ENGAGE"
	return "?"
