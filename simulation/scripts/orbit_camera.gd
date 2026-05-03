extends Camera3D

# Camera modes cycled with [C]:
# 0 = orbit center, 1 = chase ARGUS, 2 = chase HCM.

@export var controller_path: NodePath
@export var argus_path: NodePath
@export var hcm_path: NodePath
@export var orbit_radius: float = 380.0
@export var orbit_height: float = 180.0
@export var orbit_speed: float = 0.04

var _t: float = 0.0
var controller: SimController
var argus: Node3D
var hcm: Node3D

func _ready() -> void:
	controller = get_node(controller_path) as SimController
	argus = get_node(argus_path) as Node3D
	hcm = get_node(hcm_path) as Node3D

func _process(delta: float) -> void:
	_t += delta * orbit_speed
	var mode := controller.camera_mode() if controller else 0
	match mode:
		1:
			if argus:
				global_transform.origin = argus.position + Vector3(40, 25, 40)
				look_at(argus.position, Vector3.UP)
		2:
			if hcm:
				global_transform.origin = hcm.position + Vector3(60, 35, 60)
				look_at(hcm.position, Vector3.UP)
		_:
			global_transform.origin = Vector3(cos(_t) * orbit_radius, orbit_height, sin(_t) * orbit_radius)
			look_at(Vector3(0, 90, 0), Vector3.UP)
