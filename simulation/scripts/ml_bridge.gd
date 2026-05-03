extends Node
class_name MLBridge

# ---------------------------------------------------------------------------
# UDP bridge to the local PyTorch ArgusTransformer.
#
# Sends one feature-frame per call to query(); the server keeps a rolling
# window per source, runs the transformer, and replies with classification,
# range/speed, and a future trajectory (ARGUS-relative meters).
# ---------------------------------------------------------------------------

@export var host: String = "127.0.0.1"
@export var port: int = 9999

var _udp := PacketPeerUDP.new()
var last_p_target: float = 0.0
var last_range_m: float = 0.0
var last_speed_mps: float = 0.0
var last_trajectory: Array[Vector3] = []
var last_update_t: float = 0.0

func _ready() -> void:
	var err := _udp.connect_to_host(host, port)
	if err != OK:
		push_warning("MLBridge: could not connect to %s:%d (err %d)" % [host, port, err])

func _process(_dt: float) -> void:
	while _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		var txt := pkt.get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(txt)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		last_p_target = float(parsed.get("p_target", 0.0))
		last_range_m = float(parsed.get("range_m", 0.0))
		last_speed_mps = float(parsed.get("speed_mps", 0.0))
		var traj: Variant = parsed.get("trajectory", [])
		if typeof(traj) == TYPE_ARRAY:
			var pts: Array[Vector3] = []
			for item in traj:
				if typeof(item) == TYPE_ARRAY and item.size() >= 3:
					pts.append(Vector3(float(item[0]), float(item[1]), float(item[2])))
			last_trajectory = pts
		last_update_t = Time.get_ticks_msec() / 1000.0

func query(infrasound: SensorInfrasound, swir: SensorSWIR, eo: SensorEO) -> void:
	# Feature order MUST match sim_physics.FEATURE_NAMES.
	var feats: Array = [
		infrasound.anomaly_score,
		sin(infrasound.bearing_rad), cos(infrasound.bearing_rad),
		infrasound.elevation_rad,
		swir.thermal_intensity,
		sin(swir.bearing_rad), cos(swir.bearing_rad),
		swir.elevation_rad,
		swir.range_estimate_m / 100000.0,
		1.0 if swir.has_lock else 0.0,
		eo.classification_conf,
		sin(eo.bearing_rad), cos(eo.bearing_rad),
		eo.elevation_rad,
		eo.range_estimate_m / 100000.0,
		1.0 if eo.has_visual else 0.0,
	]
	var payload := JSON.stringify({"features": feats})
	_udp.put_packet(payload.to_utf8_buffer())
