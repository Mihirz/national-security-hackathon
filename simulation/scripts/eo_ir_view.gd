extends Node3D
class_name EOIRView

# ---------------------------------------------------------------------------
# 360° camera ring mounted to the glider. Four EO + four IR cameras, each
# offset from the glider belly in a different compass direction (F/R/B/L)
# and aimed at the HCM. This gives the transformer four distinct viewing
# angles of the same target while keeping every feed useful in the HUD.
# ---------------------------------------------------------------------------

@export var hcm_path: NodePath
@export var argus_path: NodePath

# Spacing between camera positions in render units (~1.25 km each).
const OFFSET_R: float = 5.0

# yaw offsets relative to argus heading: forward, starboard, aft, port.
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
	if hcm == null or argus == null:
		return
	var heading: float = argus.heading_rad if "heading_rad" in argus else 0.0
	var aim := hcm.global_position
	for i in YAWS.size():
		var yaw: float = heading + YAWS[i]
		var cam_pos := argus.global_position + Vector3(cos(yaw), -0.5, sin(yaw)) * OFFSET_R
		if (aim - cam_pos).length() > 0.5:
			if i < eo_cams.size():
				eo_cams[i].global_position = cam_pos
				eo_cams[i].look_at(aim, Vector3.UP)
			if i < ir_cams.size():
				ir_cams[i].global_position = cam_pos
				ir_cams[i].look_at(aim, Vector3.UP)
