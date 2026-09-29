extends Control
class_name OcpAmbientWave

## Procedural OCP ambient background.
## Solid stays quiet, Glass renders layered sci-fi neon strands, and Liquid
## renders slow refractive fluid blobs.  It is intentionally CanvasItem-only:
## no external texture is required, it scales to every DPI/resolution, and it
## remains safe for the native-companion D3D12 window lifecycle.

const TARGET_FRAME_INTERVAL := 1.0 / 30.0
const GLASS_STRANDS := 12
const GLASS_SAMPLES := 72
const BLOB_SAMPLES := 56

var variant := "top_right"
var accent := Color("#23b7ff")
var theme_name := "solid"
var elapsed := 0.0
var redraw_accumulator := 0.0
var phase_seed := 0.0


func configure(wave_variant: String) -> void:
	variant = wave_variant
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	anchor_right = 1.0
	anchor_bottom = 1.0
	phase_seed = float(wave_variant.length()) * 0.73
	set_process(false)
	queue_redraw()


func apply_ocp_theme(palette: Dictionary, selected_theme: String) -> void:
	accent = palette.get("accent", accent)
	theme_name = selected_theme.to_lower()
	visible = theme_name in ["glass", "liquid"]
	set_process(visible)
	queue_redraw()


func _process(delta: float) -> void:
	if not visible:
		return
	elapsed += delta
	redraw_accumulator += delta
	if redraw_accumulator < TARGET_FRAME_INTERVAL:
		return
	redraw_accumulator = 0.0
	queue_redraw()


func _draw() -> void:
	if not visible or size.x <= 2.0 or size.y <= 2.0:
		return
	if theme_name == "glass":
		_draw_glass_theme()
	elif theme_name == "liquid":
		_draw_liquid_theme()


func _draw_glass_theme() -> void:
	# Glass = airy, high-frequency neon fibres.  The strands move slowly and
	# stay near the perimeter so Settings text remains calm and readable.
	match variant:
		"shell":
			_draw_glass_field(Rect2(size.x * 0.40, -18.0, size.x * 0.62, size.y * 0.42), false, 0.82)
			_draw_glass_field(Rect2(-24.0, size.y * 0.72, size.x * 0.56, size.y * 0.30), true, 0.54)
		"bottom_left":
			_draw_glass_field(Rect2(-18.0, size.y * 0.70, size.x * 1.02, size.y * 0.31), true, 0.78)
		_:
			_draw_glass_field(Rect2(size.x * 0.52, -12.0, size.x * 0.50, size.y * 0.70), false, 0.92)


func _draw_glass_field(rect: Rect2, reverse_slope: bool, strength: float) -> void:
	var base_alpha := 0.075 * strength
	# A faint volumetric ribbon sits behind the fibres. It gives Glass a sense
	# of depth and refraction without turning the surface into an opaque panel.
	var ribbon_top := PackedVector2Array()
	var ribbon_bottom := PackedVector2Array()
	for ribbon_sample in range(GLASS_SAMPLES):
		var ribbon_t := float(ribbon_sample) / float(GLASS_SAMPLES - 1)
		var ribbon_x := rect.position.x + rect.size.x * ribbon_t
		var ribbon_slope := (-0.55 if reverse_slope else 0.52) * rect.size.y * ribbon_t
		var ribbon_wave := sin(ribbon_t * 6.1 + elapsed * 0.16 + phase_seed) * 12.0
		var ribbon_center := rect.position.y + rect.size.y * 0.43 + ribbon_slope + ribbon_wave
		ribbon_top.append(Vector2(ribbon_x, ribbon_center - rect.size.y * 0.075))
		ribbon_bottom.append(Vector2(ribbon_x, ribbon_center + rect.size.y * 0.075))
	var ribbon := PackedVector2Array(ribbon_top)
	for ribbon_index in range(ribbon_bottom.size() - 1, -1, -1):
		ribbon.append(ribbon_bottom[ribbon_index])
	draw_colored_polygon(ribbon, Color(accent.lightened(0.12), 0.018 * strength))
	for strand in range(GLASS_STRANDS):
		var points := PackedVector2Array()
		var strand_ratio := float(strand) / float(GLASS_STRANDS - 1)
		var strand_phase := elapsed * (0.18 + strand_ratio * 0.05) + phase_seed + float(strand) * 0.47
		for sample in range(GLASS_SAMPLES):
			var t := float(sample) / float(GLASS_SAMPLES - 1)
			var x := rect.position.x + rect.size.x * t
			var slope := (-0.55 if reverse_slope else 0.52) * rect.size.y * t
			var band_y := rect.position.y + rect.size.y * (0.16 + strand_ratio * 0.58)
			var wave_a := sin(t * 8.2 + strand_phase) * (6.0 + strand_ratio * 8.0)
			var wave_b := sin(t * 17.0 - strand_phase * 0.72 + float(strand)) * 3.2
			points.append(Vector2(x, band_y + slope + wave_a + wave_b))

		var line_alpha := base_alpha * (0.50 + sin(float(strand) * 1.31) * 0.18 + 0.34)
		var line_color := Color(accent.lightened(0.16 + strand_ratio * 0.16), line_alpha)
		var glow_color := Color(accent, line_alpha * 0.18)
		var width := 0.9 + fmod(float(strand), 3.0) * 0.34
		draw_polyline(points, glow_color, width + 3.5, true)
		draw_polyline(points, line_color, width, true)

		# Sparse travelling light nodes make the field feel alive without turning
		# it into a particle effect.
		if strand % 3 == 0 and points.size() > 6:
			var node_t := fposmod(elapsed * (0.035 + strand_ratio * 0.02) + strand_ratio * 0.61, 1.0)
			var node_index := mini(points.size() - 1, int(node_t * float(points.size() - 1)))
			draw_circle(points[node_index], 2.4, Color(accent.lightened(0.34), line_alpha * 1.8))
			draw_circle(points[node_index], 6.4, Color(accent, line_alpha * 0.18))


func _draw_liquid_theme() -> void:
	# Liquid = glossy refractive volume.  The cluster is made from blobs at
	# different depth planes, each with a dark depth shadow, outer bloom,
	# translucent body, inner lens, coloured core, specular cap and rim light.
	# This is intentionally CanvasItem-only so it remains safe with the native
	# companion window lifecycle while still reading as 3D.
	var secondary := accent.lerp(Color("#7d55ff"), 0.50)
	match variant:
		"shell":
			# Shell blobs stay atmospheric.  Card-local blobs carry the material
			# detail so the global layer never competes with labels or dropdowns.
			_draw_liquid_cluster(
				Vector2(size.x * 0.93, size.y * 0.10),
				minf(size.x, size.y) * 0.18,
				accent,
				secondary,
				0.34
			)
			_draw_liquid_cluster(
				Vector2(size.x * 0.025, size.y * 0.965),
				minf(size.x, size.y) * 0.12,
				secondary,
				accent,
				0.20
			)
		"bottom_left":
			_draw_liquid_cluster(
				Vector2(size.x * 0.18, size.y * 0.90),
				minf(size.x, size.y) * 0.32,
				accent,
				secondary,
				0.48
			)
		_:
			# Card-local hero material: smaller, brighter and pushed into the
			# corner so it reads as a premium 3D accent rather than a watermark.
			_draw_liquid_cluster(
				Vector2(size.x * 0.94, size.y * 0.10),
				minf(size.x, size.y) * 0.38,
				accent,
				secondary,
				0.82
			)


func _draw_liquid_cluster(center: Vector2, radius: float, primary: Color, secondary: Color, strength: float) -> void:
	if radius <= 3.0:
		return

	var master_drift := Vector2(
		sin(elapsed * 0.15 + phase_seed) * radius * 0.055,
		cos(elapsed * 0.12 + phase_seed * 0.67) * radius * 0.045
	)

	# Back-to-front depth ordering.  The rear blobs move less, the front blob
	# carries the strongest highlight and rim.  Unequal radii prevent the
	# cluster from reading as three overlapping circles.
	var descriptors := [
		{
			"offset": Vector2(-radius * 0.22, radius * 0.10),
			"radii": Vector2(radius * 0.82, radius * 0.56),
			"depth": 0.46,
			"phase": 2.35,
			"color": secondary.lerp(primary, 0.32),
		},
		{
			"offset": Vector2(radius * 0.18, radius * 0.16),
			"radii": Vector2(radius * 0.70, radius * 0.50),
			"depth": 0.68,
			"phase": 4.10,
			"color": primary.lerp(secondary, 0.44),
		},
		{
			"offset": Vector2(radius * 0.01, -radius * 0.03),
			"radii": Vector2(radius * 1.04, radius * 0.70),
			"depth": 1.00,
			"phase": 0.75,
			"color": primary,
		},
		{
			"offset": Vector2(radius * 0.28, -radius * 0.16),
			"radii": Vector2(radius * 0.28, radius * 0.22),
			"depth": 0.88,
			"phase": 5.50,
			"color": secondary.lightened(0.08),
		},
	]

	for index in range(descriptors.size()):
		var descriptor: Dictionary = descriptors[index]
		var depth := float(descriptor["depth"])
		var local_phase := elapsed * (0.17 + depth * 0.06) + phase_seed + float(descriptor["phase"])
		var local_drift := master_drift * depth + Vector2(
			sin(elapsed * (0.10 + depth * 0.045) + float(index) * 1.8) * radius * 0.035 * depth,
			cos(elapsed * (0.085 + depth * 0.035) + float(index) * 1.27) * radius * 0.028 * depth
		)
		_draw_liquid_blob(
			center + Vector2(descriptor["offset"]) + local_drift,
			Vector2(descriptor["radii"]),
			local_phase,
			Color(descriptor["color"]),
			secondary,
			strength,
			depth
		)


func _draw_liquid_blob(
	center: Vector2,
	radii: Vector2,
	phase: float,
	primary: Color,
	secondary: Color,
	strength: float,
	depth: float
) -> void:
	var deformation := 0.08 + depth * 0.045
	# Optical detail should fall off faster than body opacity. This keeps large
	# shell/background blobs atmospheric while card-local Liquid retains its 3D
	# lens, caustic and rim definition.
	var detail_strength := strength * strength
	var body := _blob_points_ellipse(center, radii, phase, deformation)
	if body.is_empty():
		return

	# 1) Depth shadow: offset down/right and slightly larger.  This is what
	# makes the fluid read as having thickness rather than being a flat decal.
	var shadow_offset := Vector2(radii.x * 0.075, radii.y * 0.10) * depth
	var shadow := _blob_points_ellipse(
		center + shadow_offset,
		radii * (1.025 + depth * 0.035),
		phase + 0.18,
		deformation * 0.92
	)
	draw_colored_polygon(shadow, Color(0.005, 0.018, 0.055, 0.25 * strength * depth))

	# 2) Outer optical bloom. Two layers are cheaper and more stable than a
	# screen-space blur, while producing a similar soft halo around the rim.
	var halo_outer := _blob_points_ellipse(center, radii * 1.13, phase - 0.24, deformation * 0.80)
	var halo_inner := _blob_points_ellipse(center, radii * 1.055, phase + 0.12, deformation * 0.88)
	draw_colored_polygon(halo_outer, Color(primary, 0.020 * strength * depth))
	draw_colored_polygon(halo_inner, Color(primary.lightened(0.10), 0.040 * strength * depth))

	# 3) Main translucent body.  The rear blobs are intentionally darker and
	# more transparent so overlaps become visible and create parallax depth.
	var body_alpha := (0.10 + depth * 0.13) * strength * depth
	var body_tint := primary.lerp(secondary, 0.10 + (1.0 - depth) * 0.24)
	draw_colored_polygon(body, Color(body_tint, body_alpha))

	# 4) Refractive inner lens: slightly offset toward the light source, with
	# a cool upper region and deeper blue lower region.
	var lens_center := center + Vector2(-radii.x * 0.095, -radii.y * 0.13)
	var lens := _blob_points_ellipse(
		lens_center,
		radii * Vector2(0.76, 0.70),
		phase + 0.62,
		deformation * 0.58
	)
	draw_colored_polygon(lens, Color(primary.lightened(0.22), (0.070 + depth * 0.085) * strength * depth))

	# 5) Coloured core.  A smaller violet/cyan body creates the same visual cue
	# seen in the approved Liquid theme preview: a volume with material inside.
	var core_center := center + Vector2(radii.x * 0.12, radii.y * 0.10)
	var core := _blob_points_ellipse(
		core_center,
		radii * Vector2(0.48, 0.42),
		phase - 0.74,
		deformation * 0.42
	)
	var core_color := primary.lerp(secondary, 0.58).lightened(0.08)
	draw_colored_polygon(core, Color(core_color, (0.045 + depth * 0.075) * strength * depth))

	# 6) Lower caustic / internal reflection. This broad translucent arc gives
	# the lower edge a gel-like thickness instead of a uniformly flat fill.
	var caustic := _arc_points(
		center + Vector2(radii.x * 0.04, radii.y * 0.06),
		radii * Vector2(0.78, 0.62),
		0.18 * PI,
		0.84 * PI,
		30
	)
	draw_polyline(caustic, Color(secondary.lightened(0.20), 0.085 * detail_strength * depth), 5.4 * depth, true)
	draw_polyline(caustic, Color(primary.lightened(0.34), 0.16 * detail_strength * depth), 1.1, true)

	# 7) Specular cap.  Two nested strokes approximate a glossy white highlight
	# without a texture or shader blur.  Front blobs receive the strongest cap.
	var specular := _arc_points(
		center + Vector2(-radii.x * 0.10, -radii.y * 0.12),
		radii * Vector2(0.60, 0.52),
		1.02 * PI,
		1.66 * PI,
		34
	)
	draw_polyline(specular, Color(primary.lightened(0.36), 0.16 * detail_strength * depth), 7.0 * depth, true)
	draw_polyline(specular, Color(Color.WHITE, 0.28 * detail_strength * depth), 1.55 + depth * 0.8, true)

	# 8) Rim lights.  A soft broad rim plus a crisp edge produces the glassy
	# outline visible in the selected Liquid preview while retaining transparency.
	var closed_body := _closed_points(body)
	draw_polyline(closed_body, Color(primary, 0.13 * detail_strength * depth), 4.2 * depth, true)
	draw_polyline(closed_body, Color(primary.lightened(0.30), 0.34 * detail_strength * depth), 1.15 + depth * 0.55, true)

	# Tiny hot spot on the foreground surface adds a final material cue.
	# Keep one premium specular point only on the true foreground blob. Rear
	# planes intentionally have no white dots; multiple hot spots read like
	# "eyes" when the ambient cluster sits in a window corner.
	if depth >= 0.98 and strength >= 0.55:
		var hot_spot := center + Vector2(-radii.x * 0.34, -radii.y * 0.28)
		draw_circle(hot_spot, 2.1 + depth, Color.WHITE, 0.46 * detail_strength)
		draw_circle(hot_spot, 7.0 + depth * 4.0, Color(primary, 0.08 * detail_strength))


func _blob_points_ellipse(center: Vector2, radii: Vector2, phase: float, deformation: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for sample in range(BLOB_SAMPLES):
		var angle := TAU * float(sample) / float(BLOB_SAMPLES)
		var wobble := (
			sin(angle * 3.0 + phase) * 0.48
			+ sin(angle * 5.0 - phase * 0.71) * 0.31
			+ sin(angle * 2.0 + phase * 0.39) * 0.21
		)
		var radial_scale := 1.0 + wobble * deformation
		points.append(center + Vector2(
			cos(angle) * radii.x * radial_scale,
			sin(angle) * radii.y * radial_scale
		))
	return points


func _arc_points(
	center: Vector2,
	radii: Vector2,
	from_angle: float,
	to_angle: float,
	steps: int
) -> PackedVector2Array:
	var points := PackedVector2Array()
	var safe_steps := maxi(steps, 2)
	for index in range(safe_steps):
		var ratio := float(index) / float(safe_steps - 1)
		var angle := lerpf(from_angle, to_angle, ratio)
		points.append(center + Vector2(cos(angle) * radii.x, sin(angle) * radii.y))
	return points


func _closed_points(points: PackedVector2Array) -> PackedVector2Array:
	var closed := PackedVector2Array(points)
	if not points.is_empty():
		closed.append(points[0])
	return closed


func _blob_points(center: Vector2, radius: float, phase: float, deformation: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for sample in range(BLOB_SAMPLES):
		var angle := TAU * float(sample) / float(BLOB_SAMPLES)
		var wobble := (
			sin(angle * 3.0 + phase) * 0.52
			+ sin(angle * 5.0 - phase * 0.73) * 0.30
			+ sin(angle * 2.0 + phase * 0.41) * 0.18
		)
		var r := radius * (1.0 + wobble * deformation)
		points.append(center + Vector2(cos(angle), sin(angle)) * r)
	return points
