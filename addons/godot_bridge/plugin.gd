@tool
extends EditorPlugin
# res://addons/godot_bridge/plugin.gd
## Godot Bridge Version 2.2.1
##
## A non-blocking local HTTP server that lets external tools (e.g. AI assistants,
## web tools) inspect, command, and modify the open Godot project safely.

const DOCK_SCRIPT_PATH = "res://addons/godot_bridge/dock.gd"
const SETTINGS_PATH = "res://addons/godot_bridge/settings.cfg"
const MAX_BODY_BYTES = 5 * 1024 * 1024  # 5 MB
const CONNECTION_TIMEOUT_MSEC = 5000

var tcp_server: TCPServer
var connections: Array = []

var bind_address: String = "127.0.0.1"
var port: int = 9090
var auth_token: String = ""

# Permissions map (Mutations set to false by default for safety; editable via cfg or UI)
var command_enabled: Dictionary = {
	"ping": true,
	"get_commands": true,
	"get_scene_tree": true,
	"get_selected_nodes": true,
	"get_node_properties": true,
	"get_node_signals": true,
	"read_file": true,
	"list_dir": true,
	"get_open_script": true,
	"write_file": false,
	"spawn_node": false,
	"spawn_packed_scene": false,
	"remove_node": false,
	"reparent_node": false,
	"set_node_property": false,
	"connect_signal": false,
	"save_scene": false,
	"open_scene": false,
	"run_project": false,
	"stop_project": false,
}

var dock: Control
var is_running: bool = false


func _enter_tree() -> void:
	_load_settings()
	var dock_script = load(DOCK_SCRIPT_PATH)
	if dock_script == null:
		push_error("Godot Bridge: could not load %s." % DOCK_SCRIPT_PATH)
		return
	dock = dock_script.new()
	dock.name = "Godot Bridge"
	dock.bridge = self
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)
	dock.refresh()


func _exit_tree() -> void:
	stop_server()
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()
		dock = null


func _process(_delta: float) -> void:
	if not is_running:
		return
	_accept_new_connections()
	_service_connections()


# ---------------------------------------------------------------------------
# Settings & Authorization
# ---------------------------------------------------------------------------

func _load_settings() -> void:
	var cfg = ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		bind_address = cfg.get_value("server", "bind_address", "127.0.0.1")
		port = int(cfg.get_value("server", "port", 9090))
		auth_token = cfg.get_value("server", "auth_token", "")
		for key in command_enabled.keys():
			command_enabled[key] = bool(cfg.get_value("commands", key, command_enabled[key]))


func save_settings() -> void:
	var cfg = ConfigFile.new()
	cfg.set_value("server", "bind_address", bind_address)
	cfg.set_value("server", "port", port)
	cfg.set_value("server", "auth_token", auth_token)
	for key in command_enabled.keys():
		cfg.set_value("commands", key, command_enabled[key])
	cfg.save(SETTINGS_PATH)


func generate_token() -> String:
	var chars := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var s := ""
	for i in range(32):
		s += chars[rng.randi_range(0, chars.length() - 1)]
	auth_token = s
	return s


# ---------------------------------------------------------------------------
# Server Lifecycle
# ---------------------------------------------------------------------------

func start_server() -> String:
	stop_server()
	tcp_server = TCPServer.new()
	var err := tcp_server.listen(port, bind_address)
	if err != OK:
		tcp_server = null
		is_running = false
		return "Failed to start (error code %d). Is port %d in use?" % [err, port]
	is_running = true
	return "Listening on %s:%d" % [bind_address, port]


func stop_server() -> void:
	for conn in connections:
		var peer: StreamPeerTCP = conn.get("peer")
		if peer and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			peer.disconnect_from_host()
	connections.clear()
	if tcp_server:
		if tcp_server.is_listening():
			tcp_server.stop()
		tcp_server = null
	is_running = false


# ---------------------------------------------------------------------------
# Connection & Async Networking
# ---------------------------------------------------------------------------

func _accept_new_connections() -> void:
	if tcp_server == null or not tcp_server.is_listening():
		return
	while tcp_server.is_connection_available():
		var peer := tcp_server.take_connection()
		connections.append({
			"peer": peer,
			"buffer": PackedByteArray(),
			"headers_parsed": false,
			"header_text": "",
			"header_end_byte": -1,
			"content_length": 0,
			"start_time": Time.get_ticks_msec(),
			"state": "reading",
			"response_data": PackedByteArray(),
			"response_offset": 0,
		})


func _find_header_end(buf: PackedByteArray) -> int:
	var sz := buf.size()
	for i in range(sz - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i + 4
	return -1


func _service_connections() -> void:
	var i := connections.size() - 1
	while i >= 0:
		var conn: Dictionary = connections[i]
		var peer: StreamPeerTCP = conn["peer"]
		peer.poll()

		var status := peer.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			connections.remove_at(i)
			i -= 1
			continue

		# Timeout Guard
		if Time.get_ticks_msec() - int(conn["start_time"]) > CONNECTION_TIMEOUT_MSEC:
			if conn["state"] == "reading":
				_queue_response(conn, 408, "{\"ok\":false,\"error\":\"Request timeout\"}")
			elif conn["state"] == "responding":
				peer.disconnect_from_host()
				connections.remove_at(i)
				i -= 1
				continue

		if conn["state"] == "reading":
			var avail := peer.get_available_bytes()
			if avail > 0:
				var chunk := peer.get_partial_data(avail)
				if chunk[0] == OK:
					conn["buffer"].append_array(chunk[1])

			if not conn["headers_parsed"]:
				var header_end_byte := _find_header_end(conn["buffer"])
				if header_end_byte != -1:
					conn["headers_parsed"] = true
					conn["header_end_byte"] = header_end_byte
					var header_bytes: PackedByteArray = conn["buffer"].slice(0, header_end_byte - 4)
					var header_text := header_bytes.get_string_from_utf8()
					conn["header_text"] = header_text

					if header_text.begins_with("OPTIONS"):
						_queue_response(conn, 200, "{}")
					else:
						var cl := 0
						for line in header_text.split("\r\n"):
							if line.to_lower().begins_with("content-length:"):
								cl = int(line.substr(line.find(":") + 1).strip_edges())

						if cl > MAX_BODY_BYTES:
							_queue_response(conn, 413, "{\"ok\":false,\"error\":\"Payload too large\"}")
						else:
							conn["content_length"] = cl

			if conn["headers_parsed"] and conn["state"] == "reading":
				var body_available: int = conn["buffer"].size() - conn["header_end_byte"]
				if body_available >= conn["content_length"]:
					var body_bytes: PackedByteArray = conn["buffer"].slice(conn["header_end_byte"], conn["header_end_byte"] + conn["content_length"])
					var body_text := body_bytes.get_string_from_utf8()
					_handle_request(conn, conn["header_text"], body_text)

		if conn["state"] == "responding":
			var resp_bytes: PackedByteArray = conn["response_data"]
			var offset: int = conn["response_offset"]
			var remaining: int = resp_bytes.size() - offset

			if remaining > 0:
				var to_send := resp_bytes.slice(offset)
				var result := peer.put_partial_data(to_send)
				if result[0] == OK:
					var sent: int = result[1]
					conn["response_offset"] = offset + sent
					remaining -= sent

			if remaining <= 0:
				peer.disconnect_from_host()
				connections.remove_at(i)

		i -= 1


# ---------------------------------------------------------------------------
# Request Dispatching
# ---------------------------------------------------------------------------

func _handle_request(conn: Dictionary, header_text: String, body_text: String) -> void:
	if not _check_auth(header_text):
		_queue_response(conn, 401, "{\"ok\":false,\"error\":\"Unauthorized\"}")
		return

	var json := JSON.new()
	if json.parse(body_text) != OK:
		_queue_response(conn, 400, "{\"ok\":false,\"error\":\"Invalid JSON payload\"}")
		return

	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		_queue_response(conn, 400, "{\"ok\":false,\"error\":\"Payload must be a JSON object\"}")
		return

	var command: String = str(data.get("command", ""))
	var payload = data.get("payload", {})

	if not command_enabled.get(command, false):
		_queue_response(conn, 403, _json_result({"ok": false, "error": "Command disabled or unknown: " + command}))
		return

	var result := _execute_command(command, payload)
	_queue_response(conn, 200, result)


func _check_auth(header_text: String) -> bool:
	if auth_token.is_empty():
		return true
	for line in header_text.split("\r\n"):
		if line.to_lower().begins_with("authorization:"):
			var value := line.substr(line.find(":") + 1).strip_edges()
			if value == "Bearer " + auth_token:
				return true
	return false


func _resolve_safe_path(path: String) -> String:
	var candidate := path.strip_edges()
	if candidate.is_empty():
		return ""
	if not candidate.begins_with("res://"):
		candidate = "res://" + candidate.trim_prefix("/")
	candidate = candidate.simplify_path()
	if not candidate.begins_with("res://") or candidate.find("..") != -1:
		return ""
	return candidate


## Files the bridge must never read or write (its own settings/token/code and Godot's cache).
func _is_protected(path: String) -> bool:
	return path.begins_with("res://addons/godot_bridge") or path.begins_with("res://.godot")


# ---------------------------------------------------------------------------
# Command Handlers
# ---------------------------------------------------------------------------

func _execute_command(command: String, payload) -> String:
	if typeof(payload) != TYPE_DICTIONARY:
		payload = {}

	match command:
		"ping":
			return _json_result({
				"ok": true,
				"message": "Godot Bridge is running.",
				"project": ProjectSettings.get_setting("application/config/name", "Untitled"),
				"godot_version": Engine.get_version_info().get("string", ""),
			})

		"get_commands":
			return _json_result({"ok": true, "commands": command_enabled})

		"get_scene_tree":
			var root = EditorInterface.get_edited_scene_root()
			if root == null:
				return _json_result({"ok": false, "error": "No scene open in editor."})
			return _json_result({"ok": true, "tree": _describe_node(root)})

		"get_selected_nodes":
			var selection = EditorInterface.get_selection().get_selected_nodes()
			var root = EditorInterface.get_edited_scene_root()
			if root == null:
				return _json_result({"ok": false, "error": "No scene open."})
			var paths := []
			for node in selection:
				paths.append({"name": node.name, "type": node.get_class(), "path": str(root.get_path_to(node))})
			return _json_result({"ok": true, "selected_nodes": paths})

		"get_node_properties":
			var target_node = _find_target_node(payload)
			if target_node == null:
				return _json_result({"ok": false, "error": "Target node not found."})

			var props := []
			for p in target_node.get_property_list():
				var usage: int = p.get("usage", 0)
				if usage & PROPERTY_USAGE_EDITOR:
					var pname: String = p["name"]
					var pval = target_node.get(pname)
					props.append({
						"name": pname,
						"type_id": p["type"],
						"type": _type_name(p["type"]),
						"value": _variant_to_json_safe(pval),
						"hint": p.get("hint", 0),
						"hint_string": p.get("hint_string", "")
					})
			return _json_result({"ok": true, "node": target_node.name, "properties": props})

		"get_node_signals":
			var target_node = _find_target_node(payload)
			if target_node == null:
				return _json_result({"ok": false, "error": "Target node not found."})

			var signals_list := []
			for sig in target_node.get_signal_list():
				var conns := []
				for conn in target_node.get_signal_connection_list(sig["name"]):
					var callable_obj = conn["callable"].get_object()
					var target_path = ""
					if callable_obj is Node:
						var root = EditorInterface.get_edited_scene_root()
						if root and root.is_ancestor_of(callable_obj):
							target_path = str(root.get_path_to(callable_obj))
						else:
							target_path = callable_obj.name
					conns.append({
						"target": target_path,
						"method": conn["callable"].get_method()
					})
				signals_list.append({"name": sig["name"], "connections": conns})
			return _json_result({"ok": true, "node": target_node.name, "signals": signals_list})

		"set_node_property":
			var target_node = _find_target_node(payload)
			if target_node == null:
				return _json_result({"ok": false, "error": "Target node not found."})

			var property_name := str(payload.get("property", ""))
			if property_name.is_empty():
				return _json_result({"ok": false, "error": "Property name required."})

			var prop_type: int = TYPE_NIL
			for p in target_node.get_property_list():
				if p["name"] == property_name:
					prop_type = p["type"]
					break

			var raw_value = payload.get("value")
			var converted_value = _convert_json_to_variant(raw_value, prop_type)
			var old_value = target_node.get(property_name)

			var ur = get_undo_redo()
			ur.create_action("Set Property: %s" % property_name)
			ur.add_do_property(target_node, property_name, converted_value)
			ur.add_undo_property(target_node, property_name, old_value)
			ur.commit_action()

			EditorInterface.mark_scene_as_unsaved()
			return _json_result({
				"ok": true,
				"message": "Set %s on %s" % [property_name, target_node.name],
				"new_value": _variant_to_json_safe(converted_value)
			})

		"spawn_node":
			var node_type := str(payload.get("node_type", ""))
			var node_name := str(payload.get("name", "NewNode"))
			var parent_node = _find_target_node(payload.get("parent", payload))

			if parent_node == null:
				parent_node = EditorInterface.get_edited_scene_root()
			if parent_node == null:
				return _json_result({"ok": false, "error": "No open scene root found."})

			if not ClassDB.class_exists(node_type) or not ClassDB.is_parent_class(node_type, "Node"):
				return _json_result({"ok": false, "error": "Invalid Node type: " + node_type})

			var new_node: Node = ClassDB.instantiate(node_type)
			new_node.name = node_name

			var root = EditorInterface.get_edited_scene_root()
			var ur = get_undo_redo()
			ur.create_action("Spawn Node: " + node_name)
			ur.add_do_method(parent_node, "add_child", new_node)
			ur.add_do_method(new_node, "set_owner", root)
			ur.add_undo_method(parent_node, "remove_child", new_node)
			ur.add_do_reference(new_node)
			ur.commit_action()

			EditorInterface.mark_scene_as_unsaved()
			return _json_result({"ok": true, "message": "Spawned %s under %s" % [node_name, parent_node.name]})

		"spawn_packed_scene":
			var scene_path := str(payload.get("scene_path", ""))
			var safe_path := _resolve_safe_path(scene_path)
			if safe_path.is_empty() or not ResourceLoader.exists(safe_path):
				return _json_result({"ok": false, "error": "PackedScene not found: " + scene_path})

			var packed_scene: PackedScene = load(safe_path)
			if packed_scene == null:
				return _json_result({"ok": false, "error": "Failed to load PackedScene."})

			var parent_node = _find_target_node(payload.get("parent", payload))
			if parent_node == null:
				parent_node = EditorInterface.get_edited_scene_root()
			if parent_node == null:
				return _json_result({"ok": false, "error": "No open scene root found."})

			var instance: Node = packed_scene.instantiate()
			var custom_name := str(payload.get("name", ""))
			if not custom_name.is_empty():
				instance.name = custom_name

			var root = EditorInterface.get_edited_scene_root()
			var ur = get_undo_redo()
			ur.create_action("Instantiate Scene: " + instance.name)
			ur.add_do_method(parent_node, "add_child", instance)
			ur.add_do_method(instance, "set_owner", root)
			ur.add_undo_method(parent_node, "remove_child", instance)
			ur.add_do_reference(instance)
			ur.commit_action()

			EditorInterface.mark_scene_as_unsaved()
			return _json_result({
				"ok": true,
				"message": "Instantiated %s under %s" % [instance.name, parent_node.name],
				"node_path": str(root.get_path_to(instance))
			})

		"remove_node":
			var target_node = _find_target_node(payload)
			if target_node == null:
				return _json_result({"ok": false, "error": "Target node not found."})
			if target_node == EditorInterface.get_edited_scene_root():
				return _json_result({"ok": false, "error": "Cannot remove scene root node."})

			var parent = target_node.get_parent()
			var ur = get_undo_redo()
			ur.create_action("Remove Node: " + target_node.name)
			ur.add_do_method(parent, "remove_child", target_node)
			ur.add_undo_method(parent, "add_child", target_node)
			ur.add_undo_method(target_node, "set_owner", target_node.owner)
			ur.add_undo_reference(target_node)
			ur.commit_action()

			EditorInterface.mark_scene_as_unsaved()
			return _json_result({"ok": true, "message": "Removed node %s" % target_node.name})

		"reparent_node":
			var target_node = _find_target_node(payload.get("target", payload))
			var new_parent = _find_target_node(payload.get("new_parent", {}))

			if target_node == null or new_parent == null:
				return _json_result({"ok": false, "error": "Target or new parent node not found."})
			if target_node == EditorInterface.get_edited_scene_root():
				return _json_result({"ok": false, "error": "Cannot reparent scene root node."})

			var old_parent = target_node.get_parent()
			if old_parent == new_parent:
				return _json_result({"ok": true, "message": "Node is already under specified parent."})

			var root = EditorInterface.get_edited_scene_root()
			var ur = get_undo_redo()
			ur.create_action("Reparent Node: " + target_node.name)
			ur.add_do_method(target_node, "reparent", new_parent)
			ur.add_undo_method(target_node, "reparent", old_parent)
			ur.add_do_method(target_node, "set_owner", root)
			ur.add_undo_method(target_node, "set_owner", root)
			ur.commit_action()

			EditorInterface.mark_scene_as_unsaved()
			return _json_result({"ok": true, "message": "Reparented %s to %s" % [target_node.name, new_parent.name]})

		"connect_signal":
			var source_node = _find_target_node(payload.get("source", {}))
			var target_node = _find_target_node(payload.get("target", {}))
			var sig_name := str(payload.get("signal", ""))
			var method_name := str(payload.get("method", ""))

			if source_node == null or target_node == null:
				return _json_result({"ok": false, "error": "Source or target node not found."})
			if sig_name.is_empty() or method_name.is_empty():
				return _json_result({"ok": false, "error": "Signal name and target method name are required."})
			if not source_node.has_signal(sig_name):
				return _json_result({"ok": false, "error": "Signal '%s' does not exist on source node." % sig_name})

			var callable := Callable(target_node, method_name)
			if source_node.is_connected(sig_name, callable):
				return _json_result({"ok": true, "message": "Signal already connected."})

			var ur = get_undo_redo()
			ur.create_action("Connect Signal: %s -> %s" % [sig_name, method_name])
			ur.add_do_method(source_node, "connect", sig_name, callable)
			ur.add_undo_method(source_node, "disconnect", sig_name, callable)
			ur.commit_action()

			EditorInterface.mark_scene_as_unsaved()
			return _json_result({"ok": true, "message": "Connected %s to %s.%s()" % [sig_name, target_node.name, method_name]})

		"read_file":
			var path := str(payload.get("path", ""))
			var safe := _resolve_safe_path(path)
			if safe.is_empty():
				return _json_result({"ok": false, "error": "Path outside project."})
			if _is_protected(safe):
				return _json_result({"ok": false, "error": "Path is protected."})
			if not FileAccess.file_exists(safe):
				return _json_result({"ok": false, "error": "File not found."})
			var f := FileAccess.open(safe, FileAccess.READ)
			var content := f.get_as_text()
			f.close()
			return _json_result({"ok": true, "path": safe, "content": content})

		"write_file":
			var path2 := str(payload.get("path", ""))
			var content2 := str(payload.get("content", ""))
			var safe2 := _resolve_safe_path(path2)
			if safe2.is_empty():
				return _json_result({"ok": false, "error": "Path outside project."})
			if _is_protected(safe2):
				return _json_result({"ok": false, "error": "Path is protected."})
			var f2 := FileAccess.open(safe2, FileAccess.WRITE)
			if f2 == null:
				return _json_result({"ok": false, "error": "Could not write file."})
			f2.store_string(content2)
			f2.close()
			var fs := EditorInterface.get_resource_filesystem()
			fs.update_file(safe2)
			fs.scan()
			var scene_reloaded := false
			var ext := safe2.get_extension().to_lower()
			if ext == "gd":
				ResourceLoader.load(safe2, "", ResourceLoader.CACHE_MODE_REPLACE)
			elif ext == "tscn" or ext == "scn":
				if EditorInterface.get_open_scenes().has(safe2):
					EditorInterface.reload_scene_from_path(safe2)
					scene_reloaded = true
			return _json_result({"ok": true, "path": safe2, "scene_reloaded": scene_reloaded})

		"list_dir":
			var path3 := str(payload.get("path", "res://"))
			var safe3 := _resolve_safe_path(path3)
			if safe3.is_empty():
				return _json_result({"ok": false, "error": "Path outside project."})
			var dir := DirAccess.open(safe3)
			if dir == null:
				return _json_result({"ok": false, "error": "Could not open directory."})
			var entries := []
			dir.list_dir_begin()
			var fname := dir.get_next()
			while fname != "":
				if fname != "." and fname != "..":
					entries.append({"name": fname, "is_dir": dir.current_is_dir()})
				fname = dir.get_next()
			dir.list_dir_end()
			return _json_result({"ok": true, "path": safe3, "entries": entries})

		"get_open_script":
			var script_editor = EditorInterface.get_script_editor()
			if script_editor == null:
				return _json_result({"ok": false, "error": "Script editor unavailable."})
			var current = script_editor.get_current_editor()
			if current == null:
				return _json_result({"ok": false, "error": "No script currently open."})
			var base_editor = current.get_base_editor()
			var text: String = base_editor.text if base_editor else ""
			var script = script_editor.get_current_script()
			var script_path: String = script.resource_path if script else ""
			return _json_result({"ok": true, "path": script_path, "content": text})

		"save_scene":
			if EditorInterface.get_edited_scene_root() == null:
				return _json_result({"ok": false, "error": "No scene open to save."})
			var err := EditorInterface.save_scene()
			if err == OK:
				return _json_result({"ok": true, "message": "Scene saved successfully."})
			return _json_result({"ok": false, "error": "Failed to save scene (code %d)." % err})

		"open_scene":
			var path := str(payload.get("path", ""))
			var safe := _resolve_safe_path(path)
			if safe.is_empty() or not FileAccess.file_exists(safe):
				return _json_result({"ok": false, "error": "Scene file not found: " + path})
			EditorInterface.open_scene_from_path(safe)
			return _json_result({"ok": true, "message": "Opened scene: " + safe})

		"run_project":
			EditorInterface.play_main_scene()
			return _json_result({"ok": true, "message": "Playing main scene."})

		"stop_project":
			EditorInterface.stop_playing_scene()
			return _json_result({"ok": true, "message": "Stopped playing scene."})

		_:
			return _json_result({"ok": false, "error": "Unrecognized command: " + command})


# ---------------------------------------------------------------------------
# Helpers & Type Conversions
# ---------------------------------------------------------------------------

func _find_target_node(target_info) -> Node:
	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		return null

	var path_str := ""
	if typeof(target_info) == TYPE_STRING or typeof(target_info) == TYPE_NODE_PATH:
		path_str = str(target_info)
	elif typeof(target_info) == TYPE_DICTIONARY:
		path_str = str(target_info.get("node_path", target_info.get("path", "")))

	if not path_str.is_empty():
		if path_str == "." or path_str == root.name:
			return root
		return root.get_node_or_null(NodePath(path_str))

	var selection = EditorInterface.get_selection().get_selected_nodes()
	if selection.size() > 0:
		return selection[0]

	return root


func _convert_json_to_variant(val, target_type: int) -> Variant:
	match target_type:
		TYPE_VECTOR2:
			if val is Array and val.size() >= 2:
				return Vector2(float(val[0]), float(val[1]))
		TYPE_VECTOR2I:
			if val is Array and val.size() >= 2:
				return Vector2i(int(val[0]), int(val[1]))
		TYPE_VECTOR3:
			if val is Array and val.size() >= 3:
				return Vector3(float(val[0]), float(val[1]), float(val[2]))
		TYPE_VECTOR3I:
			if val is Array and val.size() >= 3:
				return Vector3i(int(val[0]), int(val[1]), int(val[2]))
		TYPE_COLOR:
			if val is Array and val.size() >= 3:
				var a := float(val[3]) if val.size() >= 4 else 1.0
				return Color(float(val[0]), float(val[1]), float(val[2]), a)
			elif val is String:
				return Color.html(val)
		TYPE_NODE_PATH:
			return NodePath(str(val))
		TYPE_INT:
			return int(val)
		TYPE_FLOAT:
			return float(val)
		TYPE_BOOL:
			return bool(val)
		TYPE_STRING:
			return str(val)
		TYPE_STRING_NAME:
			return StringName(str(val))

	if val is String:
		var parsed = str_to_var(val)
		if parsed != null:
			return parsed

	return val


func _variant_to_json_safe(v: Variant) -> Variant:
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
		TYPE_STRING_NAME, TYPE_NODE_PATH, TYPE_RID:
			return str(v)
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return [v.x, v.y]
		TYPE_RECT2, TYPE_RECT2I:
			return [v.position.x, v.position.y, v.size.x, v.size.y]
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return [v.x, v.y, v.z]
		TYPE_TRANSFORM2D:
			return [v.x.x, v.x.y, v.y.x, v.y.y, v.origin.x, v.origin.y]
		TYPE_VECTOR4, TYPE_VECTOR4I:
			return [v.x, v.y, v.z, v.w]
		TYPE_PLANE:
			return [v.normal.x, v.normal.y, v.normal.z, v.d]
		TYPE_QUATERNION:
			return [v.x, v.y, v.z, v.w]
		TYPE_AABB:
			return [v.position.x, v.position.y, v.position.z, v.size.x, v.size.y, v.size.z]
		TYPE_BASIS:
			return [v.x.x, v.x.y, v.x.z, v.y.x, v.y.y, v.y.z, v.z.x, v.z.y, v.z.z]
		TYPE_TRANSFORM3D:
			return [
				v.basis.x.x, v.basis.x.y, v.basis.x.z,
				v.basis.y.x, v.basis.y.y, v.basis.y.z,
				v.basis.z.x, v.basis.z.y, v.basis.z.z,
				v.origin.x, v.origin.y, v.origin.z
			]
		TYPE_COLOR:
			return [v.r, v.g, v.b, v.a]
		TYPE_OBJECT:
			if v == null:
				return null
			if v is Resource and not v.resource_path.is_empty():
				return v.resource_path
			return str(v)
		TYPE_ARRAY:
			var res := []
			for elem in v:
				res.append(_variant_to_json_safe(elem))
			return res
		TYPE_DICTIONARY:
			var res := {}
			for key in v.keys():
				res[str(key)] = _variant_to_json_safe(v[key])
			return res
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY:
			var res := []
			for elem in v:
				res.append(elem)
			return res
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			var res := []
			for elem in v:
				res.append(_variant_to_json_safe(elem))
			return res
		_:
			return str(v)


func _type_name(type_id: int) -> String:
	match type_id:
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR3I: return "Vector3i"
		TYPE_COLOR: return "Color"
		TYPE_NODE_PATH: return "NodePath"
		TYPE_OBJECT: return "Object"
		_: return "Variant"


func _describe_node(node: Node, depth: int = 0, max_depth: int = 8) -> Dictionary:
	var desc := {"name": node.name, "type": node.get_class()}
	var scr = node.get_script()
	if scr != null and not scr.resource_path.is_empty():
		desc["script"] = scr.resource_path
	if depth > 0 and not node.scene_file_path.is_empty():
		desc["scene"] = node.scene_file_path
	if depth < max_depth and node.get_child_count() > 0:
		var children := []
		for child in node.get_children():
			children.append(_describe_node(child, depth + 1, max_depth))
		desc["children"] = children
	return desc


func _json_result(data: Dictionary) -> String:
	return JSON.stringify(data)


# ---------------------------------------------------------------------------
# HTTP Response Helper
# ---------------------------------------------------------------------------

func _queue_response(conn: Dictionary, status_code: int, response_body: String) -> void:
	var reason := _http_reason(status_code)
	var body_bytes := response_body.to_utf8_buffer()

	var response := "HTTP/1.1 %d %s\r\n" % [status_code, reason]
	response += "Content-Type: application/json; charset=utf-8\r\n"
	response += "Content-Length: %d\r\n" % body_bytes.size()
	response += "Access-Control-Allow-Origin: *\r\n"
	response += "Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n"
	response += "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
	response += "Connection: close\r\n\r\n"

	var full_bytes := response.to_utf8_buffer()
	full_bytes.append_array(body_bytes)

	conn["response_data"] = full_bytes
	conn["response_offset"] = 0
	conn["state"] = "responding"
	# Restart the timer so a 408 (or a slow response) is not cut off by the request timeout.
	conn["start_time"] = Time.get_ticks_msec()


func _http_reason(code: int) -> String:
	match code:
		200: return "OK"
		400: return "Bad Request"
		401: return "Unauthorized"
		403: return "Forbidden"
		404: return "Not Found"
		408: return "Request Timeout"
		413: return "Payload Too Large"
		_: return "Error"
