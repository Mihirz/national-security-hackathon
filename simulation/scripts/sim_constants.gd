extends Node
class_name SimConstants

# ---------------------------------------------------------------------------
# Project ARGUS — global simulation constants.
#
# World scale: 1 Godot unit = 1 meter. Altitudes from the project description
# (60,000–90,000 ft for ARGUS) are converted to meters. The HCM is modeled
# transiting at lower altitudes (Mach 5–8 cruise band, ~20–30 km AGL).
# ---------------------------------------------------------------------------

const FT_TO_M: float = 0.3048

# ARGUS solar-glider operating band (per PDF: 60,000–90,000 ft stratospheric).
const ARGUS_ALT_MIN_M: float = 60000.0 * FT_TO_M   # ~18288 m
const ARGUS_ALT_MAX_M: float = 90000.0 * FT_TO_M   # ~27432 m

# HCM transit band (PDF: "transiting at lower altitudes" than ARGUS).
const HCM_ALT_MIN_M: float = 18000.0
const HCM_ALT_MAX_M: float = 25000.0

# Speeds.
const ARGUS_CRUISE_MPS: float = 28.0       # ~55 kt loiter, solar glider.
const HCM_CRUISE_MPS: float = 1700.0       # ~Mach 5 nominal.

# Sensor ranges (line-of-sight, contested-environment tuned).
const INFRASOUND_RANGE_M: float = 220000.0 # passive, very long range, low SNR
const SWIR_RANGE_M: float = 90000.0        # thermal verification band
const EO_RANGE_M: float = 45000.0          # high-fidelity track band

# Power budget (arbitrary normalized watts for the sim).
const POWER_INFRASOUND_W: float = 0.8
const POWER_SWIR_W: float = 12.0
const POWER_EO_W: float = 18.0
const POWER_UPLINK_W: float = 35.0
const POWER_BUDGET_W: float = 80.0          # solar + battery margin

# Tiered detection thresholds (sensor-fusion confidence gates).
const TIER_DETECT_CONF: float = 0.35        # infrasound flags an anomaly
const TIER_TRACK_CONF: float = 0.65         # SWIR confirms thermal
const TIER_ENGAGE_CONF: float = 0.85        # EO + fusion lock; uplink active

# Visual scale factor for rendering — real stratospheric distances in raw
# meters make the scene unreadable, so the renderer divides by this.
const RENDER_SCALE: float = 250.0
