extends Control

# ---------------------------------------------------------------------------
# Mission-control HUD for Project ARGUS.
#
# Renders entirely in code (no external font/asset deps) so the project runs
# the moment Godot opens it. Layout:
#   - Top-left:    tier / power / energy
#   - Top-right:   sensor stack status (infrasound / SWIR / EO / uplink)
#   - Bottom-left: fusion confidence + truth-vs-estimate error
#   - Bottom-right: hotkeys
#   - Center band: tier banner + plasma-blackout warning
# ---------------------------------------------------------------------------

const COL_BG       := Color(0.02, 0.04, 0.07, 0.85)
const COL_PANEL    := Color(0.05, 0.10, 0.16, 0.92)
const COL_ACCENT   := Color(0.0, 1.0, 0.82)
const COL_WARN     := Color(1.0, 0.55, 0.1)
const COL_ALERT    := Color(1.0, 0.20, 0.25)
const COL_DIM      := Color(0.55, 0.70, 0.78)
const COL_OK       := Color(0.4, 1.0, 0.55)

const _TRAIL_MAX := 300
const _TRAIL_DT  := 0.5   # seconds between trail samples

var sim: SimController
var _t: float = 0.0
var _argus_trail: Array[Vector3] = []
var _hcm_trail:   Array[Vector3] = []
var _trail_acc:   float = 0.0
var _map_range_m: float = 200000.0   # half-range shown on tacmap, smoothed

@export var eo_viewport_path: NodePath
@export var ir_viewport_path: NodePath

var eo_rect: TextureRect
var ir_rect: TextureRect
var eo_label: Label
var ir_label: Label

var _c_prev: bool = false

func bind(controller: SimController) -> void:
	sim = controller

func _ready() -> void:
	# Bottom-right stacked sensor feed widgets: IR (top), EO (bottom).
	var feed_w := 320
	var feed_h := 200
	var margin := 16
	var hotkeys_h := 92
	var stack_bottom := -hotkeys_h - margin - margin
	# EO feed (just above the hotkeys panel)
	eo_rect = TextureRect.new()
	eo_rect.name = "EOFeed"
	eo_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	eo_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	eo_rect.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	eo_rect.offset_left = -feed_w - margin
	eo_rect.offset_top = stack_bottom - feed_h
	eo_rect.offset_right = -margin
	eo_rect.offset_bottom = stack_bottom
	add_child(eo_rect)
	eo_label = _make_label("EO  CAMERA", eo_rect)
	# IR feed above EO
	ir_rect = TextureRect.new()
	ir_rect.name = "IRFeed"
	ir_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ir_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	ir_rect.modulate = Color(1.0, 0.55, 0.25, 1.0)  # false-color tint
	ir_rect.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ir_rect.offset_left = -feed_w - margin
	ir_rect.offset_top = stack_bottom - feed_h * 2 - margin
	ir_rect.offset_right = -margin
	ir_rect.offset_bottom = stack_bottom - feed_h - margin
	add_child(ir_rect)
	ir_label = _make_label("SWIR  IR", ir_rect)

	# Bind viewports as textures (deferred so the SubViewport has rendered once).
	call_deferred("_bind_feeds")

func _bind_feeds() -> void:
	if eo_viewport_path != NodePath(""):
		var eo_vp := get_node_or_null(eo_viewport_path) as SubViewport
		if eo_vp and eo_rect:
			eo_rect.texture = eo_vp.get_texture()
	if ir_viewport_path != NodePath(""):
		var ir_vp := get_node_or_null(ir_viewport_path) as SubViewport
		if ir_vp and ir_rect:
			ir_rect.texture = ir_vp.get_texture()

func _make_label(text: String, parent: Control) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", COL_ACCENT)
	l.add_theme_font_size_override("font_size", 11)
	l.position = Vector2(6, 4)
	parent.add_child(l)
	return l

func _process(delta: float) -> void:
	_t += delta
	var c_now := Input.is_key_pressed(KEY_C)
	if c_now and not _c_prev and sim:
		sim._camera_mode = (sim._camera_mode + 1) % 3
	_c_prev = c_now
	if sim:
		_trail_acc += delta
		if _trail_acc >= _TRAIL_DT:
			_trail_acc = 0.0
			_argus_trail.append(sim.argus.truth_position_m)
			_hcm_trail.append(sim.hcm.truth_position_m)
			if _argus_trail.size() > _TRAIL_MAX:
				_argus_trail.pop_front()
			if _hcm_trail.size() > _TRAIL_MAX:
				_hcm_trail.pop_front()
		var sep := Vector2(sim.hcm.truth_position_m.x - sim.argus.truth_position_m.x,
						   sim.hcm.truth_position_m.z - sim.argus.truth_position_m.z).length()
		_map_range_m = lerp(_map_range_m, maxf(sep * 1.1, 50000.0), minf(delta * 1.5, 1.0))
	queue_redraw()

func _draw() -> void:
	if sim == null:
		return
	var sz := size

	_draw_header(sz)
	_draw_sensor_stack(sz)
	_draw_fusion_panel(sz)
	_draw_hotkeys(sz)
	_draw_center_banner(sz)

	# Compass (ARGUS-relative) + birds-eye tacmap, side by side, bottom-center.
	const COMP_W := 220.0
	const TMAP_W := 300.0
	const GAP    :=   8.0
	const H      := 300.0
	var lx := sz.x * 0.5 - (COMP_W + GAP + TMAP_W) * 0.5
	var ty := sz.y - H - 16.0
	_draw_compass(Rect2(lx,                ty, COMP_W, H))
	_draw_tacmap( Rect2(lx + COMP_W + GAP, ty, TMAP_W, H))

# ---------------------------------------------------------------------------

func _draw_header(sz: Vector2) -> void:
	var w := 360.0
	var h := 130.0
	var rect := Rect2(16, 16, w, h)
	_panel(rect)
	_label(Vector2(28, 38), "PROJECT ARGUS // STRATOSPHERIC INTERCEPT", COL_ACCENT, 14)
	_label(Vector2(28, 58), "TIER", COL_DIM, 11)

	var tier_color := COL_DIM
	match sim.power.tier:
		PowerManager.Tier.IDLE:   tier_color = COL_DIM
		PowerManager.Tier.DETECT: tier_color = COL_WARN
		PowerManager.Tier.TRACK:  tier_color = Color(1.0, 0.85, 0.2)
		PowerManager.Tier.ENGAGE: tier_color = COL_ALERT
	_label(Vector2(80, 58), sim.power.tier_name(), tier_color, 18)

	_label(Vector2(28, 88), "POWER  %5.1f W / %.0f W" % [sim.power.draw_w, SimConstants.POWER_BUDGET_W], COL_DIM, 11)
	_bar(Rect2(28, 96, w - 56, 8), sim.power.draw_w / SimConstants.POWER_BUDGET_W, COL_ACCENT)
	_label(Vector2(28, 118), "ENERGY  %.3f Wh   T+%.1fs" % [sim.power.energy_used_wh, sim.sim_time_s], COL_DIM, 11)

func _draw_sensor_stack(sz: Vector2) -> void:
	var w := 340.0
	var h := 220.0
	var rect := Rect2(sz.x - w - 16, 16, w, h)
	_panel(rect)
	_label(Vector2(rect.position.x + 12, rect.position.y + 22), "SENSOR STACK", COL_ACCENT, 13)

	var y := rect.position.y + 44
	_sensor_row(rect.position.x + 12, y,         "INFRASOUND",  sim.infrasound.is_powered, sim.infrasound.anomaly_score, "anomaly")
	_sensor_row(rect.position.x + 12, y + 38,    "SWIR  IR",    sim.swir.is_powered,       sim.swir.thermal_intensity,   "thermal")
	_sensor_row(rect.position.x + 12, y + 76,    "EO  CAMERA",  sim.eo.is_powered,         sim.eo.classification_conf,   "visual")
	_sensor_row(rect.position.x + 12, y + 114,   "SAT  UPLINK", sim.power.uplink_active,   1.0 if sim.power.uplink_active else 0.0, "active")

func _sensor_row(x: float, y: float, label: String, powered: bool, value: float, value_label: String) -> void:
	var dot_color := COL_OK if powered else COL_DIM
	draw_circle(Vector2(x + 6, y + 6), 5.0, dot_color)
	_label(Vector2(x + 22, y + 11), label, COL_DIM if not powered else Color.WHITE, 12)
	_bar(Rect2(x + 140, y + 2, 160, 8), value if powered else 0.0, COL_ACCENT if powered else COL_DIM)
	_label(Vector2(x + 140, y + 22), "%s  %.2f" % [value_label, value], COL_DIM, 10)

func _draw_fusion_panel(sz: Vector2) -> void:
	var w := 360.0
	var h := 150.0
	var rect := Rect2(16, sz.y - h - 16, w, h)
	_panel(rect)
	_label(Vector2(rect.position.x + 12, rect.position.y + 22), "SENSOR FUSION ESTIMATE", COL_ACCENT, 13)

	_label(Vector2(rect.position.x + 12, rect.position.y + 46), "CONFIDENCE", COL_DIM, 11)
	_bar(Rect2(rect.position.x + 12, rect.position.y + 52, w - 24, 10),
		sim.fusion.confidence,
		_conf_color(sim.fusion.confidence))
	_label(Vector2(rect.position.x + w - 60, rect.position.y + 46), "%.2f" % sim.fusion.confidence, COL_DIM, 11)

	var err := sim.error_m()
	var err_str := "—" if err < 0.0 else "%.0f m" % err
	_label(Vector2(rect.position.x + 12, rect.position.y + 80), "TRUTH ↔ ESTIMATE ERROR", COL_DIM, 11)
	_label(Vector2(rect.position.x + 12, rect.position.y + 100), err_str, COL_ACCENT, 18)

	if sim.fusion.has_estimate:
		var v := sim.fusion.estimated_velocity_mps.length()
		_label(Vector2(rect.position.x + 180, rect.position.y + 100), "v̂  %.0f m/s" % v, COL_DIM, 13)

	_label(Vector2(rect.position.x + 12, rect.position.y + 130),
		"Bearings-only fallback active during RF blackout." if sim.hcm.plasma_blackout else
		"Multi-modal cross-confirmation nominal.",
		COL_WARN if sim.hcm.plasma_blackout else COL_DIM, 10)

func _draw_hotkeys(sz: Vector2) -> void:
	var w := 220.0
	var h := 92.0
	var rect := Rect2(sz.x - w - 16, sz.y - h - 16, w, h)
	_panel(rect)
	_label(Vector2(rect.position.x + 12, rect.position.y + 22), "CONTROLS", COL_ACCENT, 12)
	_label(Vector2(rect.position.x + 12, rect.position.y + 42), "[R] respawn target", COL_DIM, 11)
	_label(Vector2(rect.position.x + 12, rect.position.y + 58), "[T] toggle truth marker", COL_DIM, 11)
	_label(Vector2(rect.position.x + 12, rect.position.y + 74), "[C] cycle camera", COL_DIM, 11)

func _draw_center_banner(sz: Vector2) -> void:
	if sim.power.tier == PowerManager.Tier.ENGAGE:
		var w := 380.0
		var rect := Rect2((sz.x - w) / 2.0, 14, w, 38)
		draw_rect(rect, Color(0.25, 0.0, 0.05, 0.85), true)
		draw_rect(rect, COL_ALERT, false, 1.5)
		var pulse := 0.6 + 0.4 * sin(_t * 6.0)
		_label(Vector2(rect.position.x + 24, rect.position.y + 25),
			"⚠  ENGAGE — UPLINK ACTIVE — TARGET LOCK",
			COL_ALERT * pulse, 14)
	if sim.hcm.plasma_blackout:
		var w2 := 320.0
		var rect2 := Rect2((sz.x - w2) / 2.0, 60, w2, 28)
		draw_rect(rect2, Color(0.25, 0.12, 0.0, 0.8), true)
		draw_rect(rect2, COL_WARN, false, 1.0)
		_label(Vector2(rect2.position.x + 18, rect2.position.y + 19),
			"RF BLACKOUT — PLASMA SHEATHING", COL_WARN, 12)

func _draw_compass(rect: Rect2) -> void:
	_panel(rect)
	_label(rect.position + Vector2(8.0, 14.0), "TACMAP  250 km", COL_ACCENT, 10)

	# Circle centered in the panel below the header.
	var cx     := rect.position.x + rect.size.x * 0.5
	var cy     := rect.position.y + 20.0 + (rect.size.y - 20.0) * 0.5
	var center := Vector2(cx, cy)
	var r      := minf(rect.size.x * 0.5 - 10.0, (rect.size.y - 26.0) * 0.5)

	draw_circle(center, r + 4.0, Color(0.01, 0.03, 0.06, 1.0))
	draw_arc(center, r,       0.0, TAU, 64, COL_DIM,       1.0)
	draw_arc(center, r * 0.5, 0.0, TAU, 64, COL_DIM * 0.6, 1.0)

	var scale_m_per_px := 250000.0 / r
	var argus_p := sim.argus.truth_position_m
	var hcm_p   := sim.hcm.truth_position_m

	var rel_hcm := Vector2(hcm_p.x - argus_p.x, hcm_p.z - argus_p.z) / scale_m_per_px
	if rel_hcm.length() > r:
		rel_hcm = rel_hcm.normalized() * r
	draw_circle(center, 4.0, COL_ACCENT)
	draw_circle(center + rel_hcm, 4.0, COL_ALERT)

	if sim.fusion.has_estimate:
		var est     := sim.fusion.estimated_position_m
		var rel_est := Vector2(est.x - argus_p.x, est.z - argus_p.z) / scale_m_per_px
		if rel_est.length() > r:
			rel_est = rel_est.normalized() * r
		draw_arc(center + rel_est, 6.0, 0.0, TAU, 16, COL_OK, 1.5)

	# Transformer-predicted trajectory (if MLBridge is up).
	if sim.ml_bridge and sim.ml_bridge.last_trajectory_pos.size() >= 2:
		var prev: Vector2 = center
		for i in sim.ml_bridge.last_trajectory_pos.size():
			var p: Vector3 = sim.ml_bridge.last_trajectory_pos[i]
			var rel := Vector2(p.x, p.z) / scale_m_per_px
			if rel.length() > r:
				rel = rel.normalized() * r
			var pt := center + rel
			if i > 0:
				draw_line(prev, pt, Color(0.2, 0.9, 1.0, 0.9), 1.5)
			draw_circle(pt, 2.0, Color(0.2, 0.9, 1.0, 1.0))
			prev = pt

	if sim.ml_bridge:
		var tag := "AI  p=%.2f  R=%.0fm" % [sim.ml_bridge.last_p_target, sim.ml_bridge.last_range_m]
		_label(center + Vector2(-r - 4.0, r + 14.0), tag, Color(0.2, 0.9, 1.0, 1.0), 10)


func _draw_tacmap(rect: Rect2) -> void:
	_panel(rect)
	_label(rect.position + Vector2(8.0, 14.0), "BIRDS-EYE  GLOBAL TRACK", COL_ACCENT, 10)

	const PAD := 6.0
	const HDR := 20.0
	var mr := Rect2(rect.position.x + PAD,
					rect.position.y + HDR,
					rect.size.x - PAD * 2.0, rect.size.y - HDR - PAD)
	draw_rect(mr, Color(0.01, 0.03, 0.06, 1.0), true)

	var mc    := mr.get_center()
	var ap    := sim.argus.truth_position_m
	var hp    := sim.hcm.truth_position_m
	var ox    := (ap.x + hp.x) * 0.5
	var oz    := (ap.z + hp.z) * 0.5
	var scale := minf(mr.size.x, mr.size.y) * 0.5 / _map_range_m

	# Cardinal grid — ~8 lines per half-range, clipped to map rect.
	var target_sp := _map_range_m * 0.2
	var grid_sp   := 500.0
	for ns: float in [500.0, 1000.0, 2000.0, 5000.0, 10000.0, 20000.0, 50000.0, 100000.0, 200000.0]:
		grid_sp = ns
		if ns >= target_sp:
			break
	var half_w_m  := mr.size.x * 0.5 / scale
	var half_h_m  := mr.size.y * 0.5 / scale
	var col_grid  := Color(COL_DIM.r * 0.35, COL_DIM.g * 0.35, COL_DIM.b * 0.35, 1.0)
	var col_axis  := Color(COL_DIM.r * 0.65, COL_DIM.g * 0.65, COL_DIM.b * 0.65, 1.0)
	var xi := floorf((ox - half_w_m) / grid_sp) * grid_sp
	while xi <= ox + half_w_m + grid_sp:
		var px := mc.x + (xi - ox) * scale
		if px >= mr.position.x and px <= mr.end.x:
			draw_line(Vector2(px, mr.position.y), Vector2(px, mr.end.y),
					  col_axis if absf(xi - ox) < grid_sp * 0.01 else col_grid, 1.0)
		xi += grid_sp
	var zi := floorf((oz - half_h_m) / grid_sp) * grid_sp
	while zi <= oz + half_h_m + grid_sp:
		var py := mc.y + (zi - oz) * scale
		if py >= mr.position.y and py <= mr.end.y:
			draw_line(Vector2(mr.position.x, py), Vector2(mr.end.x, py),
					  col_axis if absf(zi - oz) < grid_sp * 0.01 else col_grid, 1.0)
		zi += grid_sp

	# ARGUS trail — cyan dots, alpha fades with age.
	var n_a := _argus_trail.size()
	for i in n_a:
		var px := _map_pt(mc, ox, oz, scale, _argus_trail[i])
		if mr.has_point(px):
			var c := COL_ACCENT; c.a = float(i + 1) / float(n_a) * 0.75
			draw_circle(px, 1.5, c)

	# HCM trail — red dots, alpha fades with age.
	var n_h := _hcm_trail.size()
	for i in n_h:
		var px := _map_pt(mc, ox, oz, scale, _hcm_trail[i])
		if mr.has_point(px):
			var c := COL_ALERT; c.a = float(i + 1) / float(n_h) * 0.75
			draw_circle(px, 1.5, c)

	# Fusion estimate ring.
	if sim.fusion.has_estimate:
		var est_px := _map_pt(mc, ox, oz, scale, sim.fusion.estimated_position_m)
		if mr.has_point(est_px):
			draw_arc(est_px, 5.0, 0.0, TAU, 16, COL_OK, 1.5)

	# ARGUS marker.
	var argus_px := _map_pt(mc, ox, oz, scale, ap)
	draw_circle(argus_px, 5.0, COL_ACCENT)
	_label(argus_px + Vector2(6.0, -4.0), "ARGUS", COL_ACCENT, 8)

	# HCM marker + velocity vector (10 s projection, clamped to map rect).
	var hcm_px := _map_pt(mc, ox, oz, scale, hp)
	draw_circle(hcm_px, 5.0, COL_ALERT)
	_label(hcm_px + Vector2(6.0, -4.0), "HCM", COL_ALERT, 8)

	var vel := sim.hcm.velocity_mps
	if vel.length_squared() > 1.0:
		var tip_raw := _map_pt(mc, ox, oz, scale, hp + vel * 10.0)
		var tip := tip_raw
		if not mr.has_point(tip_raw):
			var d := tip_raw - hcm_px
			var t := 1.0
			if d.x > 0.0:   t = minf(t, (mr.end.x      - hcm_px.x) / d.x)
			elif d.x < 0.0: t = minf(t, (mr.position.x  - hcm_px.x) / d.x)
			if d.y > 0.0:   t = minf(t, (mr.end.y      - hcm_px.y) / d.y)
			elif d.y < 0.0: t = minf(t, (mr.position.y  - hcm_px.y) / d.y)
			tip = hcm_px + d * maxf(t, 0.0)
		draw_line(hcm_px, tip, COL_WARN, 1.5)
		var dir  := (tip - hcm_px).normalized()
		var perp := Vector2(-dir.y, dir.x)
		draw_line(tip, tip - dir * 5.0 + perp * 3.0, COL_WARN, 1.0)
		draw_line(tip, tip - dir * 5.0 - perp * 3.0, COL_WARN, 1.0)

	# Map border drawn last.
	draw_rect(mr, COL_DIM * 0.4, false, 1.0)

	# North arrow (top-right corner of inner map).
	var na := Vector2(mr.end.x - 14.0, mr.position.y + 14.0)
	draw_line(na + Vector2(0.0,  7.0), na + Vector2(0.0, -7.0), COL_DIM, 1.0)
	draw_line(na + Vector2(0.0, -7.0), na + Vector2(-3.0, -2.0), COL_DIM, 1.0)
	draw_line(na + Vector2(0.0, -7.0), na + Vector2( 3.0, -2.0), COL_DIM, 1.0)
	_label(na + Vector2(-2.0, 5.0), "N", COL_DIM, 7)

	# Adaptive scale bar (bottom-left of inner map).
	var bar_max_px := mr.size.x * 0.28
	var bar_km := 1.0
	for km: float in [1.0, 5.0, 10.0, 25.0, 50.0, 100.0, 200.0, 500.0]:
		if km * 1000.0 * scale < bar_max_px:
			bar_km = km
	var bar_len := bar_km * 1000.0 * scale
	var bar_y   := mr.end.y - 9.0
	var bar_x   := mr.position.x + 8.0
	draw_line(Vector2(bar_x, bar_y),           Vector2(bar_x + bar_len, bar_y),           COL_DIM * 0.8, 1.5)
	draw_line(Vector2(bar_x,           bar_y - 3.0), Vector2(bar_x,           bar_y + 3.0), COL_DIM * 0.8, 1.0)
	draw_line(Vector2(bar_x + bar_len, bar_y - 3.0), Vector2(bar_x + bar_len, bar_y + 3.0), COL_DIM * 0.8, 1.0)
	_label(Vector2(bar_x, bar_y - 11.0), "%.0f km" % bar_km, COL_DIM, 7)


func _map_pt(mc: Vector2, ox: float, oz: float, scale: float, p: Vector3) -> Vector2:
	return mc + Vector2((p.x - ox) * scale, (p.z - oz) * scale)

# ---------------------------------------------------------------------------
# Drawing helpers.
# ---------------------------------------------------------------------------

func _panel(rect: Rect2) -> void:
	draw_rect(rect, COL_PANEL, true)
	draw_rect(rect, COL_ACCENT * 0.6, false, 1.0)

func _bar(rect: Rect2, frac: float, col: Color) -> void:
	frac = clamp(frac, 0.0, 1.0)
	draw_rect(rect, Color(0.05, 0.08, 0.12, 1.0), true)
	if frac > 0.0:
		var inner := Rect2(rect.position, Vector2(rect.size.x * frac, rect.size.y))
		draw_rect(inner, col, true)
	draw_rect(rect, col * 0.7, false, 1.0)

func _label(pos: Vector2, text: String, col: Color, size_px: int) -> void:
	var f := ThemeDB.fallback_font
	draw_string(f, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size_px, col)

func _conf_color(c: float) -> Color:
	if c < SimConstants.TIER_DETECT_CONF: return COL_DIM
	if c < SimConstants.TIER_TRACK_CONF:  return COL_WARN
	if c < SimConstants.TIER_ENGAGE_CONF: return Color(1.0, 0.85, 0.2)
	return COL_ALERT
