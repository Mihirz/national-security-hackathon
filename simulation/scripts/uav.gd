class_name UAVDrone
extends Node3D

@export var uav_id: int = 0
@export var patrol_radius: float = 60.0
@export var patrol_speed: float = 25.0
@export var patrol_altitude: float = 80.0

var ir_sensor: IRSensor
var optical_sensor: OpticalSensor
var pressure_sensor: PressureSensor

var _detection: Dictionary = {
	"ir": 0.0,
	"optical": 0.0,
	"pressure": 0.0,
	"fused": 0.0,
}
var _patrol_angle: float = 0.0
var _patrol_center: Vector3
var _target: Node3D = null
var _cone_mesh: MeshInstance3D = null

signal detection_updated(uav_id: int, data: Dictionary)

func _ready() -> void:
	_patrol_center = global_position
	_patrol_angle = randf() * TAU

	ir_sensor = IRSensor.new()
	optical_sensor = OpticalSensor.new()
	pressure_sensor = PressureSensor.new()
	add_child(ir_sensor)
	add_child(optical_sensor)
	add_child(pressure_sensor)

func set_target(target: Node3D) -> void:
	_target = target

func get_fused_detection() -> float:
	return _detection.get("fused", 0.0)

func get_detection_data() -> Dictionary:
	return _detection.duplicate()

func _physics_process(delta: float) -> void:
	_patrol(delta)
	if _target:
		_sense()
		_update_cone_color()

func _patrol(delta: float) -> void:
	_patrol_angle += (patrol_speed / patrol_radius) * delta
	global_position = _patrol_center + Vector3(
		cos(_patrol_angle) * patrol_radius,
		patrol_altitude,
		sin(_patrol_angle) * patrol_radius
	)
	# Face direction of travel
	var travel_dir := Vector3(-sin(_patrol_angle), 0.0, cos(_patrol_angle))
	if travel_dir.length_squared() > 0.001:
		look_at(global_position + travel_dir, Vector3.UP)

func _sense() -> void:
	var ir: float = ir_sensor.get_detection_probability(_target)
	var optical: float = optical_sensor.get_detection_probability(_target)
	var pressure: float = pressure_sensor.get_detection_probability(_target)
	var fused: float = DataFusion.fuse_uav_sensors(ir, optical, pressure)

	_detection = {"ir": ir, "optical": optical, "pressure": pressure, "fused": fused}
	detection_updated.emit(uav_id, _detection)

func _update_cone_color() -> void:
	if not _cone_mesh:
		return
	var fused: float = _detection.get("fused", 0.0)
	var mat := _cone_mesh.material_override as StandardMaterial3D
	if not mat:
		return
	if fused >= 0.7:
		mat.albedo_color = Color(1.0, 0.1, 0.1, 0.18)
	elif fused >= 0.4:
		mat.albedo_color = Color(1.0, 0.8, 0.0, 0.14)
	else:
		mat.albedo_color = Color(0.0, 0.8, 1.0, 0.08)

func attach_cone_mesh(cone: MeshInstance3D) -> void:
	_cone_mesh = cone
