extends Node3D
class_name EOIRView

# ---------------------------------------------------------------------------
# 360° camera ring mounted to the glider. Auto-discovers the four EO and
# four IR Camera3D children inside the SubViewports under this node and
# parks them at fixed yaws (Forward / Starboard / Aft / Port) relative to
# the glider's heading. Together they cover full azimuth so an HCM can be
# spotted from any side. The transformer fuses everything; these viewports
# are visualization only.
# ---------------------------------------------------------------------------

@export var hcm_path: NodePath
@export var argus_path: NodePath

# yaws in radians, applied AFTER aligning to argus heading. 0 = forward.
const YAWS := [0.0, PI / 2.0, PI, -PI / 2.0]
const TAGS := ["F", "R", "B", "L"]

var hcm: Node3D
var argus: Node3D
var eo_cams: Array[Camera3D] = []
var ir_cams: Array[Camera3D] = []

func _ready() -> void:
	hcm = get_node_or_null(hcm_path) as Node3D
	argus = get_node_or_null(argus_path) as Node3D
	for tag in TAGS:
		var eov := get_node_or_null("EOViewport_%s" % tag) as SubViewport
		var irv := get_node_or_null("IRViewport_%s" % tag) as SubViewport
		if eov:
			var c := eov.get_node_or_null("EOCamera_%s" % tag) as Camera3D
			if c: eo_cams.append(c)
		if irv:
			var c := irv.get_node_or_null("IRCamera_%s" % tag) as Camera3D
			if c: ir_cams.append(c)

func _process(_dt: float) -> void:
	if argus == null:
		return
	var origin := argus.global_position + Vector3(0, -0.5, 0)
	var heading: float = 0.0
	if argus.has_method("get") and "heading_rad" in argus:
		heading = argus.heading_rad
	for i in YAWS.size():
		var yaw: float = heading + YAWS[i]
		var fwd := Vector3(cos(yaw), 0.0, sin(yaw))
		var aim := origin + fwd
		if i < eo_cams.size():
			eo_cams[i].global_position = origin
			eo_cams[i].look_at(aim, Vector3.UP)
		if i < ir_cams.size():
			ir_cams[i].global_position = origin
			ir_cams[i].look_at(aim, Vector3.UP)
