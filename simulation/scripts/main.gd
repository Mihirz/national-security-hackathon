class_name SimulationMain
extends Node3D

const UAV_COUNT: int = 4
const MISSILE_START: Vector3 = Vector3(-500.0, 80.0, 0.0)

const TRAJECTORY_NAMES: Array[String] = ["STRAIGHT", "TERRAIN FOLLOWING", "EVASIVE"]

var _uavs: Array[UAVDrone] = []
var _missile: HypersonicMissile
var _hud: HUD
var _camera: Camera3D
var _trajectory_mode: int = 0
var _detection_log: Array[Dictionary] = []

# Patrol center positions for each UAV — spread along expected missile corridor
const UAV_CENTERS: Array[Vector3] = [
	Vector3(-100.0, 0.0, 20.0),
	Vector3(50.0,   0.0, -30.0),
	Vector3(200.0,  0.0, 40.0),
	Vector3(350.0,  0.0, -20.0),
]

func _ready() -> void:
	_build_environment()
	_build_missile()
	_build_uavs()
	_build_camera()
	_build_hud()
	print("Simulation ready. Press [L] to launch missile.")

# ── scene construction ───────────────────────────────────────────────────────

func _build_environment() -> void:
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.04, 0.04, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.25, 0.28, 0.35)
	env.ambient_light_energy = 0.6
	env_node.environment = env
	add_child(env_node)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)

	# Ground grid — gives spatial reference
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(2000.0, 800.0)
	plane.subdivide_depth = 20
	plane.subdivide_width = 60
	ground.mesh = plane
	ground.position.y = 0.0
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.08, 0.12, 0.08)
	gmat.wireframe = true
	ground.material_override = gmat
	add_child(ground)

	# Solid ground beneath the grid
	var solid := MeshInstance3D.new()
	var solid_plane := PlaneMesh.new()
	solid_plane.size = Vector2(2000.0, 800.0)
	solid.mesh = solid_plane
	solid.position.y = -0.2
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(0.06, 0.09, 0.06)
	solid.material_override = smat
	add_child(solid)

func _build_missile() -> void:
	_missile = HypersonicMissile.new()
	_missile.name = "Missile"
	_missile.global_position = MISSILE_START

	# Body
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 1.2
	cap.height = 10.0
	body.mesh = cap
	body.rotation_degrees = Vector3(0.0, 0.0, 90.0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.75, 0.25, 0.05)
	bmat.emission_enabled = true
	bmat.emission = Color(1.0, 0.45, 0.0)
	bmat.emission_energy_multiplier = 1.8
	body.material_override = bmat
	_missile.add_child(body)

	# Exhaust glow
	var exhaust := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 2.5
	exhaust.mesh = sphere
	exhaust.position = Vector3(-7.0, 0.0, 0.0)
	var emat := StandardMaterial3D.new()
	emat.albedo_color = Color(1.0, 0.55, 0.0)
	emat.emission_enabled = true
	emat.emission = Color(1.0, 0.6, 0.1)
	emat.emission_energy_multiplier = 4.0
	exhaust.material_override = emat
	_missile.add_child(exhaust)

	_missile.missile_detected.connect(_on_missile_detected)
	_missile.missile_exited_area.connect(_on_missile_exited)
	add_child(_missile)

func _build_uavs() -> void:
	var radii: Array[float] = [70.0, 85.0, 65.0, 75.0]
	var altitudes: Array[float] = [80.0, 90.0, 75.0, 85.0]

	for i in range(UAV_COUNT):
		var uav := UAVDrone.new()
		uav.name = "UAV_%d" % i
		uav.uav_id = i
		uav.patrol_radius = radii[i]
		uav.patrol_altitude = altitudes[i]
		uav.patrol_speed = 20.0 + i * 3.0
		uav._patrol_center = UAV_CENTERS[i]
		uav.global_position = UAV_CENTERS[i] + Vector3(radii[i], altitudes[i], 0.0)

		# UAV body
		var body := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(7.0, 1.2, 4.5)
		body.mesh = box
		var bmat := StandardMaterial3D.new()
		bmat.albedo_color = Color(0.2, 0.45, 0.85)
		body.material_override = bmat
		uav.add_child(body)

		# Wing stubs
		for side in [-1, 1]:
			var wing := MeshInstance3D.new()
			var wm := BoxMesh.new()
			wm.size = Vector3(2.5, 0.4, 8.0)
			wing.mesh = wm
			wing.position = Vector3(0.0, 0.0, float(side) * 5.5)
			wing.material_override = bmat
			uav.add_child(wing)

		# Sensor cone — visualises IR detection range
		var cone := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.0
		cyl.bottom_radius = 40.0
		cyl.height = 80.0
		cone.mesh = cyl
		cone.position = Vector3(0.0, -40.0, 0.0)
		var cmat := StandardMaterial3D.new()
		cmat.albedo_color = Color(0.0, 0.8, 1.0, 0.08)
		cmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		cmat.cull_mode = BaseMaterial3D.CULL_DISABLED
		cone.material_override = cmat
		uav.add_child(cone)
		uav.attach_cone_mesh(cone)

		uav.set_target(_missile)
		uav.detection_updated.connect(_on_detection_updated)
		add_child(uav)
		_uavs.append(uav)

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.position = Vector3(100.0, 250.0, 320.0)
	_camera.rotation_degrees = Vector3(-38.0, 0.0, 0.0)
	add_child(_camera)

func _build_hud() -> void:
	_hud = HUD.new()
	add_child(_hud)
	for uav in _uavs:
		_hud.register_uav(uav.uav_id)

# ── signal handlers ──────────────────────────────────────────────────────────

func _on_detection_updated(uav_id: int, data: Dictionary) -> void:
	_hud.update_uav_detection(uav_id, data)
	_recompute_system_confidence()

func _recompute_system_confidence() -> void:
	var per_uav: Array[float] = []
	for uav in _uavs:
		per_uav.append(uav.get_fused_detection())
	var system_confidence: float = DataFusion.fuse_multi_uav(per_uav)
	_hud.update_fused_confidence(system_confidence)
	_missile.record_detection(system_confidence)

	_detection_log.append({
		"time": Time.get_ticks_msec() * 0.001,
		"confidence": system_confidence,
	})

func _on_missile_detected(confidence: float) -> void:
	print("[DETECTION EVENT] confidence=%.3f" % confidence)

func _on_missile_exited() -> void:
	print("[SIM] Missile exited area. Total detection frames: %d" % _detection_log.size())

# ── input ────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and (event as InputEventKey).pressed):
		return
	var key := (event as InputEventKey).keycode

	match key:
		KEY_L:
			_missile.launch(Vector3(1, 0, 0))
			print("[SIM] Missile launched — trajectory: %s" % TRAJECTORY_NAMES[_trajectory_mode])

		KEY_R:
			_missile.reset()
			_missile.global_position = MISSILE_START
			_detection_log.clear()
			print("[SIM] Reset.")

		KEY_T:
			_trajectory_mode = (_trajectory_mode + 1) % 3
			_missile.trajectory_mode = _trajectory_mode as HypersonicMissile.TrajectoryMode
			_hud.update_trajectory_mode(TRAJECTORY_NAMES[_trajectory_mode])
			print("[SIM] Trajectory: %s" % TRAJECTORY_NAMES[_trajectory_mode])

		# Camera presets
		KEY_1:
			_camera.position = Vector3(100.0, 250.0, 320.0)
			_camera.rotation_degrees = Vector3(-38.0, 0.0, 0.0)
		KEY_2:
			_camera.position = Vector3(100.0, 500.0, 0.0)
			_camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		KEY_3:
			_camera.position = Vector3(-600.0, 120.0, 0.0)
			_camera.rotation_degrees = Vector3(-15.0, -90.0, 0.0)
