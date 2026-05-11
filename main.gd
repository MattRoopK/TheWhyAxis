extends Control

const AblyClient := preload("res://ably.gd")

enum GameState { LOBBY, ROUND_CLUE, ROUND_GUESS, ROUND_RESULTS, GAME_OVER }

const CLUE_DURATION := 120.0
const GUESS_DURATION := 120.0
const RESULTS_DURATION := 6.0
const ROUNDS_PER_PLAYER := 3
const LABELS_CSV_PATH := "res://Game_Lists/game_lists.csv"

var label_rows: Array = []  # Array of [pos_x, neg_x, pos_y, neg_y]
var _unused_label_indices: Array[int] = []  # shuffle bag — refills when empty
var x_pos_label := "Scary"
var x_neg_label := "Not scary"
var y_pos_label := "Dangerous"
var y_neg_label := "Safe"

# Scoring rings, sized as fractions of a quadrant's diameter (quadrant = 0.5 in
#
@export var RING_BULLSEYE_RADIUS := .025  # 10% of a quadrant
@export var RING_MIDDLE_RADIUS   := .075  # 30% of a quadrant
@export var RING_OUTER_RADIUS    := .2  # 80% of a quadrant

const PLAYER_COLORS: Array[Color] = [
	Color("#e63946"), Color("#f4a261"), Color("#e9c46a"), Color("#52b788"),
	Color("#48cae4"), Color("#5e60ce"), Color("#ff70a6"), Color("#90e0ef"),
]

@onready var lobby_panel: Control = $LobbyPanel
@onready var game_panel: Control = $GamePanel
@onready var room_code_label: Label = $Footer/VBoxContainer/RoomCodeLabel
@onready var players_label: Label = $LobbyPanel/VBoxContainer/PlayersLabel
@onready var status_label: Label = $LobbyPanel/VBoxContainer/StatusLabel
@onready var header_label: Label = $GamePanel/HeaderLabel
@onready var timer_label: Label = $GamePanel/TimerLabel
@onready var scores_label: Label = $GamePanel/ScoresLabel
@onready var game_over_label: Label = $GamePanel/GameOverLabel
@onready var chart: Control = $GamePanel/Chart

var ably: Node
var room_code := ""
var channel_name := ""

var state: int = GameState.LOBBY
var players: Array[String] = []
var player_colors: Dictionary = {}
var scores: Dictionary = {}
var round_index := 0
var total_rounds := 0
var clue_giver := ""
var current_target := Vector2(0.5, 0.5)
var guesses: Dictionary = {}
var locked_in: Dictionary = {}
var phase_timer := 0.0


func _ready() -> void:
	randomize()
	room_code = _generate_room_code()
	channel_name = "game-" + room_code
	room_code_label.text = "Room Code: " + room_code
	status_label.text = "Connecting to Ably..."
	players_label.text = "Waiting for players..."

	_load_label_rows()
	_pick_random_labels()
	chart.set_axes(x_pos_label, x_neg_label, y_pos_label, y_neg_label)

	ably = AblyClient.new()
	ably.name = "Ably"
	add_child(ably)
	ably.ably_connected.connect(_on_ably_connected)
	ably.ably_disconnected.connect(_on_ably_disconnected)
	ably.ably_message.connect(_on_ably_message)
	ably.connect_to_ably()


func _process(delta: float) -> void:
	if state == GameState.ROUND_CLUE or state == GameState.ROUND_GUESS or state == GameState.ROUND_RESULTS:
		phase_timer = max(0.0, phase_timer - delta)
		timer_label.text = "%d" % int(ceil(phase_timer))
		if phase_timer <= 0.0:
			_advance_phase()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		var w := get_window()
		if w.mode == Window.MODE_FULLSCREEN or w.mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
			w.mode = Window.MODE_WINDOWED
		else:
			w.mode = Window.MODE_FULLSCREEN
		get_viewport().set_input_as_handled()


func _load_label_rows() -> void:
	label_rows.clear()
	var f := FileAccess.open(LABELS_CSV_PATH, FileAccess.READ)
	if f == null:
		push_warning("Could not open labels CSV at %s; falling back to defaults." % LABELS_CSV_PATH)
		return
	var is_header := true
	while not f.eof_reached():
		var row := f.get_csv_line()
		if is_header:
			is_header = false
			continue
		if row.size() < 4:
			continue
		var pos_x := row[0].strip_edges()
		var neg_x := row[1].strip_edges()
		var pos_y := row[2].strip_edges()
		var neg_y := row[3].strip_edges()
		if pos_x.is_empty() and neg_x.is_empty() and pos_y.is_empty() and neg_y.is_empty():
			continue
		label_rows.append([pos_x, neg_x, pos_y, neg_y])


func _pick_random_labels() -> void:
	if label_rows.is_empty():
		return
	if _unused_label_indices.is_empty():
		_refill_label_bag()
	var pick_idx := randi() % _unused_label_indices.size()
	var row_idx := _unused_label_indices[pick_idx]
	_unused_label_indices.remove_at(pick_idx)
	var row: Array = label_rows[row_idx]
	x_pos_label = row[0]
	x_neg_label = row[1]
	y_pos_label = row[2]
	y_neg_label = row[3]


func _refill_label_bag() -> void:
	_unused_label_indices.clear()
	for i in label_rows.size():
		_unused_label_indices.append(i)


func _axis_labels_payload() -> Dictionary:
	return {
		"x_pos": x_pos_label,
		"x_neg": x_neg_label,
		"y_pos": y_pos_label,
		"y_neg": y_neg_label,
	}


func _generate_room_code() -> String:
	const LETTERS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	var code := ""
	for i in 4:
		code += LETTERS[randi() % LETTERS.length()]
	return code


func _on_ably_connected() -> void:
	status_label.text = "Waiting for players to join..."
	ably.attach(channel_name)


func _on_ably_disconnected() -> void:
	status_label.text = "Disconnected from Ably"


func _on_ably_message(payload: Dictionary) -> void:
	var t: String = str(payload.get("type", ""))
	match t:
		"player_joined":
			_handle_player_joined(payload)
		"start_game":
			_handle_start_game(payload)
		"clue_given":
			_handle_clue_given(payload)
		"guess_update":
			_handle_guess_update(payload)
		"final_answer":
			_handle_final_answer(payload)


# ── Lobby ──────────────────────────────────────────────────────────────────

func _handle_player_joined(payload: Dictionary) -> void:
	if state != GameState.LOBBY:
		return
	var n: String = str(payload.get("name", "")).strip_edges()
	if n.is_empty():
		return
	if not players.has(n):
		players.append(n)
		scores[n] = 0
		player_colors[n] = PLAYER_COLORS[(players.size() - 1) % PLAYER_COLORS.size()]
		chart.pin_colors = player_colors
	_refresh_lobby_display()
	ably.publish(channel_name, {
		"type": "room_confirmed",
		"room": room_code,
		"for": n,
		"is_host": players.size() > 0 and players[0] == n,
		"axis_labels": _axis_labels_payload(),
	})


func _refresh_lobby_display() -> void:
	if players.is_empty():
		players_label.text = "Waiting for players..."
		status_label.text = "Open the controller URL on your phone to join."
		return
	players_label.text = "Joined: " + ", ".join(PackedStringArray(players))
	status_label.text = "Host (%s) can start the game from their phone." % players[0]


func _handle_start_game(payload: Dictionary) -> void:
	if state != GameState.LOBBY:
		return
	if players.is_empty():
		return
	var requester: String = str(payload.get("name", ""))
	if requester != players[0]:
		return
	total_rounds = players.size() * ROUNDS_PER_PLAYER
	round_index = 0
	lobby_panel.visible = false
	game_panel.visible = true
	game_over_label.visible = false
	chart.visible = true
	_start_round()


# ── Round flow ─────────────────────────────────────────────────────────────

func _start_round() -> void:
	round_index += 1
	clue_giver = players[(round_index - 1) % players.size()]
	current_target = Vector2(randf(), randf())
	guesses.clear()
	locked_in.clear()
	_pick_random_labels()
	chart.set_axes(x_pos_label, x_neg_label, y_pos_label, y_neg_label)
	chart.clear_round()
	chart.set_pins({})
	state = GameState.ROUND_CLUE
	phase_timer = CLUE_DURATION
	header_label.text = "Round %d / %d — %s is the clue giver (thinking...)" % [round_index, total_rounds, clue_giver]
	_refresh_scores_display()
	ably.publish(channel_name, {
		"type": "round_start",
		"round_index": round_index,
		"total_rounds": total_rounds,
		"clue_giver": clue_giver,
		"target": {"x": current_target.x, "y": current_target.y},
		"axis_labels": _axis_labels_payload(),
		"duration": CLUE_DURATION,
	})


func _handle_clue_given(payload: Dictionary) -> void:
	if state != GameState.ROUND_CLUE:
		return
	if str(payload.get("name", "")) != clue_giver:
		return
	_start_guess_phase()


func _start_guess_phase() -> void:
	state = GameState.ROUND_GUESS
	phase_timer = GUESS_DURATION
	header_label.text = "Round %d / %d — %s gave the clue. Guess!" % [round_index, total_rounds, clue_giver]
	ably.publish(channel_name, {
		"type": "guess_phase_start",
		"clue_giver": clue_giver,
		"duration": GUESS_DURATION,
	})


func _handle_guess_update(payload: Dictionary) -> void:
	if state != GameState.ROUND_GUESS:
		return
	var n: String = str(payload.get("name", ""))
	if n == clue_giver or not players.has(n):
		return
	if locked_in.get(n, false):
		return
	var g: Dictionary = payload.get("guess", {})
	var v := Vector2(
		clampf(float(g.get("x", 0.5)), 0.0, 1.0),
		clampf(float(g.get("y", 0.5)), 0.0, 1.0)
	)
	guesses[n] = v
	chart.set_pins(guesses)


func _handle_final_answer(payload: Dictionary) -> void:
	if state != GameState.ROUND_GUESS:
		return
	var n: String = str(payload.get("name", ""))
	if n == clue_giver or not players.has(n):
		return
	var g: Dictionary = payload.get("guess", {})
	if not g.is_empty():
		var v := Vector2(
			clampf(float(g.get("x", 0.5)), 0.0, 1.0),
			clampf(float(g.get("y", 0.5)), 0.0, 1.0)
		)
		guesses[n] = v
		chart.set_pins(guesses)
	locked_in[n] = true
	var guesser_count := 0
	for p in players:
		if p != clue_giver:
			guesser_count += 1
	if guesser_count > 0 and locked_in.size() >= guesser_count:
		_start_results_phase()


func _start_results_phase() -> void:
	state = GameState.ROUND_RESULTS
	phase_timer = RESULTS_DURATION
	var round_scores := _calculate_round_scores()
	var clue_giver_pts := 0
	for n in round_scores:
		clue_giver_pts += int(round_scores[n])
	round_scores[clue_giver] = clue_giver_pts
	for n in round_scores:
		scores[n] = int(scores.get(n, 0)) + int(round_scores[n])
	chart.reveal_target(current_target, [RING_OUTER_RADIUS, RING_MIDDLE_RADIUS, RING_BULLSEYE_RADIUS])
	header_label.text = "Round %d results — clue giver %s earned %d" % [round_index, clue_giver, clue_giver_pts]
	_refresh_scores_display()
	ably.publish(channel_name, {
		"type": "round_results",
		"target": {"x": current_target.x, "y": current_target.y},
		"clue_giver": clue_giver,
		"round_scores": round_scores,
		"totals": scores,
	})


func _calculate_round_scores() -> Dictionary:
	var rs := {}
	for n in players:
		if n == clue_giver:
			continue
		if not guesses.has(n):
			rs[n] = 0
			continue
		var g: Vector2 = guesses[n]
		var dist := g.distance_to(current_target)
		var pts := 0
		if dist < RING_BULLSEYE_RADIUS:
			pts = 3
		elif dist < RING_MIDDLE_RADIUS:
			pts = 2
		elif dist < RING_OUTER_RADIUS:
			pts = 1
		rs[n] = pts
	return rs


func _advance_phase() -> void:
	match state:
		GameState.ROUND_CLUE:
			_start_guess_phase()
		GameState.ROUND_GUESS:
			_start_results_phase()
		GameState.ROUND_RESULTS:
			if round_index >= total_rounds:
				_end_game()
			else:
				_start_round()


func _end_game() -> void:
	state = GameState.GAME_OVER
	timer_label.text = ""
	chart.visible = false
	game_over_label.visible = true
	var ranked := _ranked_scores()
	var winner_text := "GAME OVER"
	if ranked.size() > 0:
		var top: Array = ranked[0]
		winner_text = "GAME OVER\n%s wins with %d points!" % [top[0], top[1]]
	game_over_label.text = winner_text
	header_label.text = "Final Standings"
	_refresh_scores_display()
	ably.publish(channel_name, {
		"type": "game_over",
		"totals": scores,
	})


func _ranked_scores() -> Array:
	var arr: Array = []
	for n in players:
		arr.append([n, int(scores.get(n, 0))])
	arr.sort_custom(func(a, b): return int(a[1]) > int(b[1]))
	return arr


func _refresh_scores_display() -> void:
	if players.is_empty():
		scores_label.text = ""
		return
	var parts: Array[String] = []
	for n in players:
		parts.append("%s: %d" % [n, int(scores.get(n, 0))])
	scores_label.text = "    ".join(PackedStringArray(parts))
