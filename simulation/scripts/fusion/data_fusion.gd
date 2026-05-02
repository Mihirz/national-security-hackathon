class_name DataFusion
extends RefCounted

const IR_WEIGHT: float = 0.40
const OPTICAL_WEIGHT: float = 0.30
const PRESSURE_WEIGHT: float = 0.30

const DETECTION_THRESHOLD: float = 0.50

# Weighted linear combination of a single UAV's three sensor readings.
static func fuse_uav_sensors(ir: float, optical: float, pressure: float) -> float:
	return (ir * IR_WEIGHT) + (optical * OPTICAL_WEIGHT) + (pressure * PRESSURE_WEIGHT)

# Complementary probability fusion across multiple UAVs:
# P(detect) = 1 - product(1 - Pi)
# This ensures any UAV with a high reading raises the system confidence.
static func fuse_multi_uav(per_uav_fused: Array[float]) -> float:
	if per_uav_fused.is_empty():
		return 0.0
	var complement: float = 1.0
	for p: float in per_uav_fused:
		complement *= (1.0 - p)
	return 1.0 - complement

static func is_detected(fused_probability: float) -> bool:
	return fused_probability >= DETECTION_THRESHOLD
