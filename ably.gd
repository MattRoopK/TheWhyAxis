extends Node

signal ably_connected
signal ably_disconnected
signal ably_message(payload: Dictionary)

const ABLY_KEY := "I9x_TQ.XW3Uyw:gMx6lM_kYxHcVb6Wq_EQBy1f4UYxZB3J5Ip46oswjSM"
const HEARTBEAT_INTERVAL := 10.0
const RECONNECT_DELAY := 2.0

var _ws := WebSocketPeer.new()
var _connected := false
var _was_connected := false
var _pending_attach: Array[String] = []
var _attached_channels: Array[String] = []
var _idle_seconds := 0.0
var _reconnect_timer := 0.0
var _should_reconnect := false
var _msg_serial := 0


func connect_to_ably() -> void:
	_should_reconnect = true
	_open_socket()


func _open_socket() -> void:
	_ws = WebSocketPeer.new()
	_idle_seconds = 0.0
	_reconnect_timer = 0.0
	_msg_serial = 0
	var url := "wss://realtime.ably.io/?key=%s&v=1.2&format=json" % ABLY_KEY
	var err := _ws.connect_to_url(url)
	if err != OK:
		push_error("Ably connect failed: %s" % err)
		_reconnect_timer = RECONNECT_DELAY


func attach(channel_name: String) -> void:
	if not _attached_channels.has(channel_name):
		_attached_channels.append(channel_name)
	if _connected:
		_send({"action": 10, "channel": channel_name})
	elif not _pending_attach.has(channel_name):
		_pending_attach.append(channel_name)


func publish(channel_name: String, payload: Dictionary) -> void:
	if not _connected:
		push_warning("Ably not connected; dropping message")
		return
	_send({
		"action": 15,
		"channel": channel_name,
		"msgSerial": _msg_serial,
		"messages": [{"name": "msg", "data": JSON.stringify(payload)}]
	})
	_msg_serial += 1


func _send(obj: Dictionary) -> void:
	_idle_seconds = 0.0
	_ws.send_text(JSON.stringify(obj))


func _process(delta: float) -> void:
	_ws.poll()
	var state := _ws.get_ready_state()
	match state:
		WebSocketPeer.STATE_OPEN:
			while _ws.get_available_packet_count() > 0:
				var raw := _ws.get_packet().get_string_from_utf8()
				_handle_raw(raw)
			if _connected:
				_idle_seconds += delta
				if _idle_seconds >= HEARTBEAT_INTERVAL:
					_send({"action": 0}) # HEARTBEAT
		WebSocketPeer.STATE_CLOSED:
			if _was_connected:
				_was_connected = false
				_connected = false
				print("Ably disconnected (code=%d, reason=%s)" % [_ws.get_close_code(), _ws.get_close_reason()])
				ably_disconnected.emit()
				if _should_reconnect:
					_reconnect_timer = RECONNECT_DELAY
			if _should_reconnect and _reconnect_timer > 0.0:
				_reconnect_timer -= delta
				if _reconnect_timer <= 0.0:
					print("Ably reconnecting...")
					_pending_attach = _attached_channels.duplicate()
					_open_socket()


func _handle_raw(text: String) -> void:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return
	var action: int = int(data.get("action", -1))
	match action:
		0: # HEARTBEAT from server — already counts as activity, no reply needed
			pass
		4: # CONNECTED
			_connected = true
			_was_connected = true
			print("Ably connected")
			ably_connected.emit()
			for ch in _pending_attach:
				_send({"action": 10, "channel": ch})
			_pending_attach.clear()
		11: # ATTACHED
			print("Ably channel attached: ", data.get("channel", ""))
		15: # MESSAGE
			for msg in data.get("messages", []):
				var d = msg.get("data", null)
				if typeof(d) == TYPE_STRING:
					var parsed = JSON.parse_string(d)
					if typeof(parsed) == TYPE_DICTIONARY:
						ably_message.emit(parsed)
				elif typeof(d) == TYPE_DICTIONARY:
					ably_message.emit(d)
		9: # ERROR
			print("Ably error response: ", data)
			push_error("Ably error: %s" % str(data))
