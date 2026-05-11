extends Control

var x_pos_label := "Scary"
var x_neg_label := "Not scary"
var y_pos_label := "Dangerous"
var y_neg_label := "Safe"
var target := Vector2.ZERO
var show_target := false
var ring_radii: Array = []     # normalized radii (outer to inner) shown at reveal
var pins: Dictionary = {}      # name -> Vector2 in [0,1]
var pin_colors: Dictionary = {} # name -> Color


func set_pins(d: Dictionary) -> void:
	pins = d.duplicate()
	queue_redraw()


func set_axes(x_pos: String, x_neg: String, y_pos: String, y_neg: String) -> void:
	x_pos_label = x_pos
	x_neg_label = x_neg
	y_pos_label = y_pos
	y_neg_label = y_neg
	queue_redraw()


func reveal_target(t: Vector2, radii: Array = []) -> void:
	target = t
	ring_radii = radii
	show_target = true
	queue_redraw()


func hide_target() -> void:
	show_target = false
	queue_redraw()


func clear_round() -> void:
	pins.clear()
	show_target = false
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)

	draw_rect(rect, Color(0.05, 0.06, 0.13, 1.0))

	# Quadrant cross-lines
	var cx := size.x * 0.5
	var cy := size.y * 0.5
	var grid_color := Color(0.32, 0.34, 0.5, 1.0)
	draw_line(Vector2(0, cy), Vector2(size.x, cy), grid_color, 2.0)
	draw_line(Vector2(cx, 0), Vector2(cx, size.y), grid_color, 2.0)

	# Border
	draw_rect(rect, Color(0.45, 0.5, 0.75, 1.0), false, 3.0)

	# Edge labels
	var font := ThemeDB.fallback_font
	var fs := 28
	var label_color := Color(0.92, 0.92, 1.0, 1.0)

	var top_size := font.get_string_size(y_pos_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	draw_string(font, Vector2((size.x - top_size.x) * 0.5, fs + 4), y_pos_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, label_color)

	var bot_size := font.get_string_size(y_neg_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	draw_string(font, Vector2((size.x - bot_size.x) * 0.5, size.y - 12), y_neg_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, label_color)

	draw_string(font, Vector2(14, cy - 8), x_neg_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, label_color)
	var right_size := font.get_string_size(x_pos_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	draw_string(font, Vector2(size.x - right_size.x - 14, cy - 8), x_pos_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, label_color)

	# Target reveal
	if show_target:
		var t := _to_pixel(target)
		# Rings — sized to the scoring radii. Chart is non-square, so a circle in
		# normalized [0,1] space (which is what scoring uses) renders as an ellipse.
		var ring_colors := [
			Color(1.0, 0.4, 0.4, 0.18),
			Color(1.0, 0.4, 0.4, 0.45),
			Color(1.0, 0.3, 0.3, 1.0),
		]
		for i in ring_radii.size():
			var r: float = float(ring_radii[i])
			var col: Color = ring_colors[i] if i < ring_colors.size() else ring_colors[ring_colors.size() - 1]
			_draw_filled_ellipse(t, r * size.x, r * size.y, col)
		draw_line(t + Vector2(-30, 0), t + Vector2(30, 0), Color(1, 1, 1, 0.7), 1.5)
		draw_line(t + Vector2(0, -30), t + Vector2(0, 30), Color(1, 1, 1, 0.7), 1.5)

	# Pins
	for n in pins:
		var p := _to_pixel(pins[n])
		var col: Color = pin_colors.get(n, Color.WHITE)
		draw_circle(p, 14.0, col)
		draw_arc(p, 14.0, 0.0, TAU, 32, Color(0, 0, 0, 0.5), 2.0)
		var label_pos := p + Vector2(18, 6)
		draw_string(font, label_pos + Vector2(1, 1), n, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(0, 0, 0, 0.6))
		draw_string(font, label_pos, n, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, col.lightened(0.4))


func _to_pixel(c: Vector2) -> Vector2:
	return Vector2(c.x * size.x, (1.0 - c.y) * size.y)


func _draw_filled_ellipse(center: Vector2, rx: float, ry: float, color: Color, segments: int = 64) -> void:
	var points := PackedVector2Array()
	for i in segments:
		var a := TAU * float(i) / float(segments)
		points.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(points, color)
