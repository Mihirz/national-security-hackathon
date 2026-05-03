extends Node3D
class_name EOIRView

# ---------------------------------------------------------------------------
# Glider-mounted gimbal camera. Holds two Camera3D children — one inside an
# EO SubViewport (visible-light) and one inside an IR SubViewport (the IR
# environment material is set up in the scene). Both cameras are kept aimed
# at the HCM each tick so the HUD can mirror the feeds bottom-right.
# ---------------------------------------------------------------------------

@export var hcm_path: NodePath
@export var argus_path: NodePath
@export var eo_camera_path: NodePath
@export var ir_camera_path: NodePath

var hcm: Node3D
var argus: Node3D
var eo_cam: Camera3D
var ir_cam: Camera3D

func _ready() -> void:
	hcm = get_node_or_null(hcm_path) as Node3D
	argus = get_node_or_null(argus_path) as Node3D
	eo_cam = get_node_or_null(eo_camera_path) as Camera3D
	ir_cam = get_node_or_null(ir_camera_path) as Camera3D

func _process(_dt: float) -> void:
	if hcm == null or argus == null:
		return
	var aim := hcm.global_position
	# Mount slightly below glider belly.
	var mount := argus.global_position + Vector3(0, -0.5, 0)
	if eo_cam:
		eo_cam.global_position = mount
		if (aim - mount).length() > 0.5:
			eo_cam.look_at(aim, Vector3.UP)
	if ir_cam:
		ir_cam.global_position = mount
		if (aim - mount).length() > 0.5:
			ir_cam.look_at(aim, Vector3.UP)
