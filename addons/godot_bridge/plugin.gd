@tool
extends EditorPlugin
# res://addons/godot_bridge/plugin.gd
## Godot Bridge Version 2.3.0
##
## A non-blocking HTTP server that lets external tools (e.g. AI assistants,
## Open WebUI) inspect, command, and modify the open Godot project.
## Every command can be switched on/off from the dock. Mutating commands are
## off by default.

const DOCK_SCRIPT_PATH = "res://addons/godot_bridge/dock.gd"
const SETTINGS_PATH = "res://addons/godot_bridge/settings.cfg"
const MAX_BODY_BYTES = 5 * 1024 * 1024  # 5 MB
const CONNECTION_TIMEOUT_MSEC = 5000
const MAX_READ_CHARS = 60000
const MAX_LIST_ENTRIES = 500
const LOOPBACK_ADDRESSES = ["127.0.0.1", "localhost"]

var tcp_server: TCPServer
var connections: Array = []

var bind_address: String = "127.0.0.1"
var port: int = 9090
var auth_token: String = ""
var cors_origin: String = ""  # empty = send no CORS headers (recommended for server-side tools)
var auto_start: bool = false

var dock: Control
var is_running: bool = false
var _output_mark: int = 0

# Permissions map (mutations are false by default; editable via the dock or settings.cfg)
var command_enabled: Dictionary = {
	# Read-only
	"ping": true,
	"get_commands": true,
	"get_scene_tree": true,
	"get_selected_nodes": true,
	"get_node_properties": true,
	"get_node_signals": true,
	"get_open_scenes": true,
	"read_file": true,
	"list_dir": true,
	"get_open_script": true,
	"get_output": true,
	"validate_script": true,
	"class_info": true,
	# Mutating
	"write_file": false,
	"make_dir": false,
	"delete_file": false,
	"spawn_node": false,
	"spawn_packed_scene": false,
	"remove_node": false,
	"reparent_node": false,
	"rename_node": false,
	"set_node_property": false,
	"attach_script": false,
	"add_to_group": false,
	"connect_signal": false,
	"create_scene": false,
	"save_scene": false,
	"open_scene": false,
	"set_main_scene": false,
	"add_input_action": false,
	"run_project": false,
	"run_current_scene": false,
	"stop_project": false,
}

# Returned by get_commands so the model knows the exact payload keys.
const COMMAND_DOCS = {
	"ping": "No payload. Returns project name and Godot version.",
	"get_commands": "No payload. Lists every command, whether it is enabled, and its payload.",
	"get_scene_tree": "Payload: {max_depth?: int}. Returns nodes with name, type, path (use it as node_path), script.",
	"get_selected_nodes": "No payload. Nodes currently selected in the editor.",
	"get_node_properties": "Payload: {node_path, filter?: substring}. node_path '.' is the scene root.",
	"get_node_signals": "Payload: {node_path, connected_only?: bool}.",
	"get_open_scenes": "No payload. Scene files currently open in the editor.",
	"read_file": "Payload: {path, offset?: int, limit?: int}. Long files are paged; check 'truncated'.",
	"list_dir": "Payload: {path?, recursive?: bool}. Default path is res://.",
	"get_open_script": "No payload. Script currently open in the script editor.",
	"get_output": "Payload: {max_chars?: int, new_only?: bool}. Editor Output panel text: parse errors, print() output, runtime errors. Use new_only to see only lines since the last get_output call.",
	"validate_script": "Payload: {path}. Parse-checks a .gd file. On failure call get_output for the exact message.",
	"class_info": "Payload: {class, filter?: substring}. Real methods, properties and signals from ClassDB.",
	"write_file": "Payload: {path, content}. Replaces the WHOLE file and creates missing folders. read_file first.",
	"make_dir": "Payload: {path}.",
	"delete_file": "Payload: {path}. Deletes one file.",
	"spawn_node": "Payload: {node_type, name?, parent?: node_path, properties?: {}}. Parent defaults to the scene root. Returns node_path. In properties: vectors and colors are arrays or strings, resources are res://path or {type, properties}.",
	"spawn_packed_scene": "Payload: {scene_path, name?, parent?: node_path, properties?: {}}. Returns node_path.",
	"remove_node": "Payload: {node_path}.",
	"reparent_node": "Payload: {node_path, new_parent}.",
	"rename_node": "Payload: {node_path, new_name}. Returns the new node_path.",
	"set_node_property": "Payload: {node_path, property, value}. Vector2/3 and Color as arrays, Color also as a name or #hex, resources as res://path or {type, properties}. Script: use attach_script.",
	"attach_script": "Payload: {node_path, script_path}.",
	"add_to_group": "Payload: {node_path, group}.",
	"connect_signal": "Payload: {source, target, signal, method}. source and target are node paths. The connection is saved with the scene.",
	"create_scene": "Payload: {path, root_type?, root_name?, overwrite?: bool}. Creates a .tscn with one root node and opens it.",
	"save_scene": "No payload. Saves the currently edited scene.",
	"open_scene": "Payload: {path}.",
	"set_main_scene": "Payload: {path}. Sets the scene that run_project plays.",
	"add_input_action": "Payload: {action, keys: [\"W\", \"Up\", \"Space\"]}. Replaces the action's key events.",
	"run_project": "No payload. Plays the main scene (set_main_scene first). Then call get_output.",
	"run_current_scene": "No payload. Plays the scene open in the editor. Then call get_output.",
	"stop_project": "No payload.",
}


func _enter_tree() -> void:
	_load_settings()
	var dock_script = load(DOCK_SCRIPT_PATH)
	if dock_script == null:
		push_error("Godot Bridge: could not load %s." % DOCK_SCRIPT_PATH)
		return
	dock = dock_script.new()
	dock.name = "Godot Bridge"
	dock.set("bridge", self)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)
	if auto_start:
		start_server()
	dock.call("refresh")


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
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		bind_address = str(cfg.get_value("server", "bind_address", "127.0.0.1"))
		port = int(cfg.get_value("server", "port", 9090))
		auth_token = str(cfg.get_value("server", "auth_token", ""))
		cors_origin = str(cfg.get_value("server", "cors_origin", ""))
		auto_start = bool(cfg.get_value("server", "auto_start", false))
		for key in command_enabled.keys():
			command_enabled[key] = bool(cfg.get_value("commands", key, command_enabled[key]))
	else:
		# First run: create a token straight away so nothing is ever unauthenticated by accident.
		generate_token()
		save_settings()


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("server", "bind_address", bind_address)
	cfg.set_value("server", "port", port)
	cfg.set_value("server", "auth_token", auth_token)
	cfg.set_value("server", "cors_origin", cors_origin)
	cfg.set_value("server", "auto_start", auto_start)
	for key in command_enabled.keys():
		cfg.set_value("commands", key, command_enabled[key])
	cfg.save(SETTINGS_PATH)


func generate_token() -> String:
	auth_token = Crypto.new().generate_random_bytes(24).hex_encode()
	return auth_token


# ---------------------------------------------------------------------------
# Server Lifecycle
# ---------------------------------------------------------------------------

func start_server() -> String:
	stop_server()
	if not LOOPBACK_ADDRESSES.has(bind_address) and auth_token.is_empty():
		return "Refusing to start: set a token when binding beyond localhost."
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

		# Timeout guard
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
		_queue_response(conn, 403, _err("Command disabled or unknown: " + command))
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


## Protected from writing/deleting (project.godot may still be read).
func _is_write_protected(path: String) -> bool:
	return _is_protected(path) or path == "res://project.godot"


func _err(message: String) -> String:
	return JSON.stringify({"ok": false, "error": message})


func _ok(extra: Dictionary = {}) -> String:
	var result: Dictionary = {"ok": true}
	result.merge(extra)
	return JSON.stringify(result)


# ---------------------------------------------------------------------------
# Command Handlers
# ---------------------------------------------------------------------------

func _execute_command(command: String, payload) -> String:
	if typeof(payload) != TYPE_DICTIONARY:
		payload = {}

	match command:
		"ping": return _cmd_ping()
		"get_commands": return _cmd_get_commands()
		"get_scene_tree": return _cmd_get_scene_tree(payload)
		"get_selected_nodes": return _cmd_get_selected_nodes()
		"get_node_properties": return _cmd_get_node_properties(payload)
		"get_node_signals": return _cmd_get_node_signals(payload)
		"get_open_scenes": return _ok({"scenes": Array(EditorInterface.get_open_scenes())})
		"read_file": return _cmd_read_file(payload)
		"list_dir": return _cmd_list_dir(payload)
		"get_open_script": return _cmd_get_open_script()
		"get_output": return _cmd_get_output(payload)
		"validate_script": return _cmd_validate_script(payload)
		"class_info": return _cmd_class_info(payload)
		"write_file": return _cmd_write_file(payload)
		"make_dir": return _cmd_make_dir(payload)
		"delete_file": return _cmd_delete_file(payload)
		"spawn_node": return _cmd_spawn_node(payload)
		"spawn_packed_scene": return _cmd_spawn_packed_scene(payload)
		"remove_node": return _cmd_remove_node(payload)
		"reparent_node": return _cmd_reparent_node(payload)
		"rename_node": return _cmd_rename_node(payload)
		"set_node_property": return _cmd_set_node_property(payload)
		"attach_script": return _cmd_attach_script(payload)
		"add_to_group": return _cmd_add_to_group(payload)
		"connect_signal": return _cmd_connect_signal(payload)
		"create_scene": return _cmd_create_scene(payload)
		"save_scene": return _cmd_save_scene()
		"open_scene": return _cmd_open_scene(payload)
		"set_main_scene": return _cmd_set_main_scene(payload)
		"add_input_action": return _cmd_add_input_action(payload)
		"run_project":
			EditorInterface.play_main_scene()
			return _ok({"message": "Playing main scene."})
		"run_current_scene":
			EditorInterface.play_current_scene()
			return _ok({"message": "Playing current scene."})
		"stop_project":
			EditorInterface.stop_playing_scene()
			return _ok({"message": "Stopped playing scene."})
		_:
			return _err("Unrecognized command: " + command)


# ----- Read-only ------------------------------------------------------------

func _cmd_ping() -> String:
	return _ok({
		"message": "pong - Godot Bridge is running.",
		"project": ProjectSettings.get_setting("application/config/name", "Untitled"),
		"godot_version": Engine.get_version_info().get("string", ""),
	})


func _cmd_get_commands() -> String:
	var out := {}
	for key in command_enabled.keys():
		out[key] = {"enabled": command_enabled[key], "usage": COMMAND_DOCS.get(key, "")}
	return _ok({"commands": out})


func _cmd_get_scene_tree(p: Dictionary) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene open in editor.")
	var max_depth := int(p.get("max_depth", 8))
	return _ok({"tree": _describe_node(root, root, 0, max_depth)})


func _cmd_get_selected_nodes() -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene open.")
	var items := []
	for node in EditorInterface.get_selection().get_selected_nodes():
		items.append({"name": str(node.name), "type": node.get_class(), "path": _rel_path(node)})
	return _ok({"selected_nodes": items})


func _cmd_get_node_properties(p: Dictionary) -> String:
	var node := _find_target_node(p)
	if node == null:
		return _err("Target node not found.")
	var filter := str(p.get("filter", "")).to_lower()
	var props := []
	for prop in node.get_property_list():
		var usage: int = prop.get("usage", 0)
		if usage & PROPERTY_USAGE_EDITOR:
			var pname: String = prop["name"]
			if not filter.is_empty() and not pname.to_lower().contains(filter):
				continue
			props.append({
				"name": pname,
				"type": _type_name(prop["type"]),
				"value": _variant_to_json_safe(node.get(pname)),
				"hint": prop.get("hint", 0),
				"hint_string": prop.get("hint_string", ""),
			})
	return _ok({"node": str(node.name), "properties": props})


func _cmd_get_node_signals(p: Dictionary) -> String:
	var node := _find_target_node(p)
	if node == null:
		return _err("Target node not found.")
	var root := EditorInterface.get_edited_scene_root()
	var connected_only := bool(p.get("connected_only", false))
	var signals_list := []
	for sig in node.get_signal_list():
		var conns := []
		for conn in node.get_signal_connection_list(sig["name"]):
			var callable_obj = conn["callable"].get_object()
			var target_path := ""
			if callable_obj is Node:
				if root and root.is_ancestor_of(callable_obj):
					target_path = str(root.get_path_to(callable_obj))
				else:
					target_path = str(callable_obj.name)
			conns.append({"target": target_path, "method": str(conn["callable"].get_method())})
		if connected_only and conns.is_empty():
			continue
		signals_list.append({"name": sig["name"], "connections": conns})
	return _ok({"node": str(node.name), "signals": signals_list})


func _cmd_read_file(p: Dictionary) -> String:
	var safe := _resolve_safe_path(str(p.get("path", "")))
	if safe.is_empty():
		return _err("Path outside project.")
	if _is_protected(safe):
		return _err("Path is protected.")
	if not FileAccess.file_exists(safe):
		return _err("File not found.")
	var f := FileAccess.open(safe, FileAccess.READ)
	if f == null:
		return _err("Could not open file.")
	var content := f.get_as_text()
	f.close()
	var total := content.length()
	var offset := maxi(0, int(p.get("offset", 0)))
	var limit := int(p.get("limit", MAX_READ_CHARS))
	var truncated := offset + limit < total
	content = content.substr(offset, limit)
	var result := {"path": safe, "content": content, "total_chars": total, "truncated": truncated}
	if truncated:
		result["warning"] = "Output truncated. Read the rest with offset=%d before rewriting this file." % (offset + limit)
	return _ok(result)


func _cmd_list_dir(p: Dictionary) -> String:
	var safe := _resolve_safe_path(str(p.get("path", "res://")))
	if safe.is_empty():
		return _err("Path outside project.")
	if DirAccess.open(safe) == null:
		return _err("Could not open directory.")
	if bool(p.get("recursive", false)):
		var flat := []
		_collect_dir(safe, "", flat, 0)
		return _ok({"path": safe, "files": flat, "capped": flat.size() >= MAX_LIST_ENTRIES})
	var dir := DirAccess.open(safe)
	var entries := []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not _skip_entry(fname):
			entries.append({"name": fname, "is_dir": dir.current_is_dir()})
		fname = dir.get_next()
	dir.list_dir_end()
	return _ok({"path": safe, "entries": entries})


func _skip_entry(fname: String) -> bool:
	return fname.begins_with(".") or fname.ends_with(".import") or fname.ends_with(".uid")


func _collect_dir(path: String, prefix: String, out: Array, depth: int) -> void:
	if depth > 6 or out.size() >= MAX_LIST_ENTRIES:
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not _skip_entry(fname) and out.size() < MAX_LIST_ENTRIES:
			if dir.current_is_dir():
				out.append(prefix + fname + "/")
				_collect_dir(path.path_join(fname), prefix + fname + "/", out, depth + 1)
			else:
				out.append(prefix + fname)
		fname = dir.get_next()
	dir.list_dir_end()


func _cmd_get_open_script() -> String:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return _err("Script editor unavailable.")
	var current = script_editor.get_current_editor()
	if current == null:
		return _err("No script currently open.")
	var base_editor = current.get_base_editor()
	var text: String = base_editor.text if base_editor else ""
	var cur_script = script_editor.get_current_script()
	var script_path: String = cur_script.resource_path if cur_script else ""
	return _ok({"path": script_path, "content": text})


func _cmd_get_output(p: Dictionary) -> String:
	var log_node := _find_by_class(EditorInterface.get_base_control(), "EditorLog")
	if log_node == null:
		return _err("Output panel not found.")
	var label := _find_by_class(log_node, "RichTextLabel") as RichTextLabel
	if label == null:
		return _err("Output panel not found.")
	var txt := label.get_parsed_text()
	var total := txt.length()
	if bool(p.get("new_only", false)):
		if _output_mark > total:
			_output_mark = 0
		txt = txt.substr(_output_mark)
	_output_mark = total
	var max_chars := int(p.get("max_chars", 4000))
	if txt.length() > max_chars:
		txt = txt.substr(txt.length() - max_chars)
	return _ok({"output": txt.strip_edges()})


func _cmd_validate_script(p: Dictionary) -> String:
	var safe := _resolve_safe_path(str(p.get("path", "")))
	if safe.is_empty() or not FileAccess.file_exists(safe):
		return _err("File not found.")
	if safe.get_extension().to_lower() != "gd":
		return _err("Only .gd files can be validated.")
	var source := FileAccess.get_file_as_string(safe)
	# Drop class_name so validation does not clash with the already-registered global class.
	var regex := RegEx.create_from_string("(?m)^class_name[ \\t]+\\w+")
	source = regex.sub(source, "", true)
	var gs := GDScript.new()
	gs.source_code = source
	var verr := gs.reload()
	if verr == OK:
		return _ok({"valid": true})
	return JSON.stringify({
		"ok": false,
		"valid": false,
		"error": "Script failed to parse (%s). Call get_output for the message." % error_string(verr),
	})


func _cmd_class_info(p: Dictionary) -> String:
	var cname := str(p.get("class", ""))
	if not ClassDB.class_exists(cname):
		return _err("Unknown class: " + cname)
	var filter := str(p.get("filter", "")).to_lower()
	var methods := []
	for m in ClassDB.class_get_method_list(cname, true):
		var mname: String = m["name"]
		if not filter.is_empty() and not mname.to_lower().contains(filter):
			continue
		var arg_names := PackedStringArray()
		for a in m.get("args", []):
			arg_names.append(str(a["name"]))
		methods.append("%s(%s)" % [mname, ", ".join(arg_names)])
	var props := []
	for x in ClassDB.class_get_property_list(cname, true):
		var xname: String = x["name"]
		if (x.get("usage", 0) & PROPERTY_USAGE_EDITOR) and (filter.is_empty() or xname.to_lower().contains(filter)):
			props.append(xname)
	var sigs := []
	for s in ClassDB.class_get_signal_list(cname, true):
		var sname: String = s["name"]
		if filter.is_empty() or sname.to_lower().contains(filter):
			sigs.append(sname)
	return _ok({
		"class": cname,
		"parent": str(ClassDB.get_parent_class(cname)),
		"methods": methods,
		"properties": props,
		"signals": sigs,
	})


# ----- Files ----------------------------------------------------------------

func _cmd_write_file(p: Dictionary) -> String:
	if not p.has("content"):
		return _err("content is required (send the complete file).")
	var safe := _resolve_safe_path(str(p.get("path", "")))
	if safe.is_empty():
		return _err("Path outside project.")
	if _is_write_protected(safe):
		return _err("Path is protected.")
	DirAccess.make_dir_recursive_absolute(safe.get_base_dir())
	var f := FileAccess.open(safe, FileAccess.WRITE)
	if f == null:
		return _err("Could not write file.")
	f.store_string(str(p["content"]))
	f.close()
	var fs := EditorInterface.get_resource_filesystem()
	fs.update_file(safe)
	if not fs.is_scanning():
		fs.scan()
	var scene_reloaded := false
	var ext := safe.get_extension().to_lower()
	if ext == "gd":
		ResourceLoader.load(safe, "", ResourceLoader.CACHE_MODE_REPLACE)
	elif ext == "tscn" or ext == "scn":
		if EditorInterface.get_open_scenes().has(safe):
			EditorInterface.reload_scene_from_path(safe)
			scene_reloaded = true
	return _ok({"path": safe, "scene_reloaded": scene_reloaded})


func _cmd_make_dir(p: Dictionary) -> String:
	var safe := _resolve_safe_path(str(p.get("path", "")))
	if safe.is_empty() or _is_write_protected(safe):
		return _err("Invalid or protected path.")
	var err := DirAccess.make_dir_recursive_absolute(safe)
	if err != OK:
		return _err("Could not create directory (code %d)." % err)
	EditorInterface.get_resource_filesystem().scan()
	return _ok({"path": safe})


func _cmd_delete_file(p: Dictionary) -> String:
	var safe := _resolve_safe_path(str(p.get("path", "")))
	if safe.is_empty() or _is_write_protected(safe):
		return _err("Invalid or protected path.")
	if not FileAccess.file_exists(safe):
		return _err("File not found.")
	var err := DirAccess.remove_absolute(safe)
	if err != OK:
		return _err("Could not delete file (code %d)." % err)
	EditorInterface.get_resource_filesystem().scan()
	return _ok({"message": "Deleted " + safe})


# ----- Scene editing --------------------------------------------------------

func _cmd_spawn_node(p: Dictionary) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene open in editor.")
	var node_type := str(p.get("node_type", ""))
	if not ClassDB.class_exists(node_type) or not ClassDB.is_parent_class(node_type, "Node") or not ClassDB.can_instantiate(node_type):
		return _err("Invalid Node type: " + node_type)
	var parent_node := _resolve_parent(p)
	if parent_node == null:
		return _err("Parent node not found.")

	var new_node := ClassDB.instantiate(node_type) as Node
	new_node.name = str(p.get("name", node_type))
	var skipped := _apply_properties(new_node, p.get("properties", {}))

	var ur := _begin_action("Spawn Node: " + str(new_node.name))
	ur.add_do_method(self, "_do_add_node", parent_node, new_node, root)
	ur.add_undo_method(parent_node, "remove_child", new_node)
	ur.add_do_reference(new_node)
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()

	var result := {
		"message": "Spawned %s under %s" % [new_node.name, parent_node.name],
		"node_path": _rel_path(new_node),
	}
	if not skipped.is_empty():
		result["skipped_properties"] = skipped
	return _ok(result)


func _cmd_spawn_packed_scene(p: Dictionary) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene open in editor.")
	var scene_path := str(p.get("scene_path", ""))
	var safe := _resolve_safe_path(scene_path)
	if safe.is_empty() or not ResourceLoader.exists(safe):
		return _err("PackedScene not found: " + scene_path)
	if safe == root.scene_file_path:
		return _err("Cannot instance a scene inside itself.")
	var packed := load(safe) as PackedScene
	if packed == null:
		return _err("Failed to load PackedScene.")
	var parent_node := _resolve_parent(p)
	if parent_node == null:
		return _err("Parent node not found.")

	var instance := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	var custom_name := str(p.get("name", ""))
	if not custom_name.is_empty():
		instance.name = custom_name
	var skipped := _apply_properties(instance, p.get("properties", {}))

	var ur := _begin_action("Instantiate Scene: " + str(instance.name))
	ur.add_do_method(self, "_do_add_node", parent_node, instance, root)
	ur.add_undo_method(parent_node, "remove_child", instance)
	ur.add_do_reference(instance)
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()

	var result := {
		"message": "Instantiated %s under %s" % [instance.name, parent_node.name],
		"node_path": _rel_path(instance),
	}
	if not skipped.is_empty():
		result["skipped_properties"] = skipped
	return _ok(result)


func _cmd_remove_node(p: Dictionary) -> String:
	var root := EditorInterface.get_edited_scene_root()
	var node := _find_target_node(p, false)
	if node == null:
		return _err("Target node not found. Provide node_path.")
	if node == root:
		return _err("Cannot remove scene root node.")

	var old_parent := node.get_parent()
	var idx := node.get_index()
	var ur := _begin_action("Remove Node: " + str(node.name))
	ur.add_do_method(old_parent, "remove_child", node)
	ur.add_undo_method(self, "_undo_remove_node", old_parent, node, idx, root)
	ur.add_undo_reference(node)
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"message": "Removed node %s" % node.name})


func _cmd_reparent_node(p: Dictionary) -> String:
	var root := EditorInterface.get_edited_scene_root()
	var target_info = p["target"] if p.has("target") else p
	var node := _find_target_node(target_info, false)
	var new_parent := _find_target_node(p.get("new_parent", ""), false)
	if node == null or new_parent == null:
		return _err("Target or new parent node not found.")
	if node == root:
		return _err("Cannot reparent scene root node.")
	if new_parent == node or node.is_ancestor_of(new_parent):
		return _err("Cannot reparent a node under itself.")

	var old_parent := node.get_parent()
	if old_parent == new_parent:
		return _ok({"message": "Node is already under specified parent."})
	var old_idx := node.get_index()

	var ur := _begin_action("Reparent Node: " + str(node.name))
	ur.add_do_method(self, "_do_reparent", node, new_parent, root)
	ur.add_undo_method(self, "_undo_reparent", node, old_parent, old_idx, root)
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return _ok({
		"message": "Reparented %s to %s" % [node.name, new_parent.name],
		"node_path": _rel_path(node),
	})


func _cmd_rename_node(p: Dictionary) -> String:
	var node := _find_target_node(p, false)
	if node == null:
		return _err("Target node not found. Provide node_path.")
	var new_name := str(p.get("new_name", "")).strip_edges()
	if new_name.is_empty() or new_name != new_name.validate_node_name():
		return _err("Invalid node name.")
	var parent_node := node.get_parent()
	if parent_node != null:
		var clash := parent_node.get_node_or_null(NodePath(new_name))
		if clash != null and clash != node:
			return _err("A sibling named '%s' already exists." % new_name)

	var ur := _begin_action("Rename Node: " + new_name)
	ur.add_do_property(node, "name", new_name)
	ur.add_undo_property(node, "name", node.name)
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"message": "Renamed to " + new_name, "node_path": _rel_path(node)})


func _cmd_set_node_property(p: Dictionary) -> String:
	var node := _find_target_node(p, false)
	if node == null:
		return _err("Target node not found. Provide node_path.")
	var prop := str(p.get("property", ""))
	if prop.is_empty():
		return _err("Property name required.")
	if not p.has("value"):
		return _err("value is required.")
	var ptype := _property_type(node, prop)
	if ptype == -1:
		return _err("Unknown property '%s' on %s (%s). Use get_node_properties." % [prop, node.name, node.get_class()])

	var raw = p["value"]
	var converted = _convert_json_to_variant(raw, ptype)
	if converted == null and raw != null:
		return _err("Could not convert value for '%s' (expected %s)." % [prop, _type_name(ptype)])
	var old_value = node.get(prop)

	var ur := _begin_action("Set Property: " + prop)
	ur.add_do_property(node, prop, converted)
	ur.add_undo_property(node, prop, old_value)
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return _ok({
		"message": "Set %s on %s" % [prop, node.name],
		"new_value": _variant_to_json_safe(node.get(prop)),
	})


func _cmd_attach_script(p: Dictionary) -> String:
	var node := _find_target_node(p, false)
	if node == null:
		return _err("Target node not found. Provide node_path.")
	var sp := _resolve_safe_path(str(p.get("script_path", "")))
	if sp.is_empty() or not ResourceLoader.exists(sp):
		return _err("Script not found. write_file it first.")
	var scr := load(sp) as Script
	if scr == null:
		return _err("Not a valid script.")
	var base_type := str(scr.get_instance_base_type())
	if not base_type.is_empty() and not node.is_class(base_type):
		return _err("Script extends %s but the node is %s." % [base_type, node.get_class()])

	var ur := _begin_action("Attach Script")
	ur.add_do_property(node, "script", scr)
	ur.add_undo_property(node, "script", node.get_script())
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"message": "Attached %s to %s" % [sp, node.name]})


func _cmd_add_to_group(p: Dictionary) -> String:
	var node := _find_target_node(p, false)
	if node == null:
		return _err("Target node not found. Provide node_path.")
	var group := str(p.get("group", "")).strip_edges()
	if group.is_empty():
		return _err("group is required.")
	if node.is_in_group(group):
		return _ok({"message": "Node is already in group."})
	var ur := _begin_action("Add to Group: " + group)
	ur.add_do_method(node, "add_to_group", StringName(group), true)
	ur.add_undo_method(node, "remove_from_group", StringName(group))
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"message": "Added %s to group %s" % [node.name, group]})


func _cmd_connect_signal(p: Dictionary) -> String:
	var source := _find_target_node(p.get("source", ""), false)
	var target := _find_target_node(p.get("target", ""), false)
	var sig_name := str(p.get("signal", ""))
	var method_name := str(p.get("method", ""))
	if source == null or target == null:
		return _err("Source or target node not found.")
	if sig_name.is_empty() or method_name.is_empty():
		return _err("Signal name and target method name are required.")
	if not source.has_signal(sig_name):
		return _err("Signal '%s' does not exist on source node." % sig_name)

	var callable := Callable(target, method_name)
	if source.is_connected(sig_name, callable):
		return _ok({"message": "Signal already connected."})

	var ur := _begin_action("Connect Signal: %s -> %s" % [sig_name, method_name])
	# CONNECT_PERSIST makes the connection get saved into the .tscn file.
	ur.add_do_method(source, "connect", sig_name, callable, CONNECT_PERSIST)
	ur.add_undo_method(source, "disconnect", sig_name, callable)
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()

	var result := {"message": "Connected %s to %s.%s()" % [sig_name, target.name, method_name]}
	if not target.has_method(method_name):
		result["warning"] = "Target has no method '%s' yet. Make sure its script defines it and is attached." % method_name
	return _ok(result)


# ----- Scenes & project -----------------------------------------------------

func _cmd_create_scene(p: Dictionary) -> String:
	var root_type := str(p.get("root_type", "Node2D"))
	var safe := _resolve_safe_path(str(p.get("path", "")))
	if safe.is_empty() or _is_write_protected(safe) or safe.get_extension().to_lower() != "tscn":
		return _err("Path must be a .tscn file inside the project.")
	if FileAccess.file_exists(safe) and not bool(p.get("overwrite", false)):
		return _err("Scene already exists. Pass overwrite=true to replace it.")
	if not ClassDB.class_exists(root_type) or not ClassDB.is_parent_class(root_type, "Node") or not ClassDB.can_instantiate(root_type):
		return _err("Invalid root type: " + root_type)

	DirAccess.make_dir_recursive_absolute(safe.get_base_dir())
	var new_root := ClassDB.instantiate(root_type) as Node
	new_root.name = str(p.get("root_name", safe.get_file().get_basename().to_pascal_case()))
	var packed := PackedScene.new()
	var pack_err := packed.pack(new_root)
	new_root.free()
	if pack_err != OK:
		return _err("Could not pack scene (code %d)." % pack_err)
	var save_err := ResourceSaver.save(packed, safe)
	if save_err != OK:
		return _err("Save failed (code %d)." % save_err)

	EditorInterface.get_resource_filesystem().update_file(safe)
	EditorInterface.open_scene_from_path(safe)
	return _ok({"message": "Created and opened " + safe, "path": safe})


func _cmd_save_scene() -> String:
	if EditorInterface.get_edited_scene_root() == null:
		return _err("No scene open to save.")
	var err := EditorInterface.save_scene()
	if err == OK:
		return _ok({"message": "Scene saved successfully."})
	return _err("Failed to save scene (code %d)." % err)


func _cmd_open_scene(p: Dictionary) -> String:
	var path := str(p.get("path", ""))
	var safe := _resolve_safe_path(path)
	if safe.is_empty() or not FileAccess.file_exists(safe):
		return _err("Scene file not found: " + path)
	EditorInterface.open_scene_from_path(safe)
	return _ok({"message": "Opened scene: " + safe})


func _cmd_set_main_scene(p: Dictionary) -> String:
	var safe := _resolve_safe_path(str(p.get("path", "")))
	var ext := safe.get_extension().to_lower()
	if safe.is_empty() or not FileAccess.file_exists(safe) or (ext != "tscn" and ext != "scn"):
		return _err("Scene file not found.")
	ProjectSettings.set_setting("application/run/main_scene", safe)
	var err := ProjectSettings.save()
	if err != OK:
		return _err("Could not save project settings (code %d)." % err)
	return _ok({"message": "Main scene set to " + safe})


func _cmd_add_input_action(p: Dictionary) -> String:
	var action := str(p.get("action", "")).strip_edges()
	if action.is_empty():
		return _err("Action name required.")
	var keys = p.get("keys", [])
	if typeof(keys) != TYPE_ARRAY:
		keys = [keys]
	var events := []
	var bad := []
	for k in keys:
		var code := OS.find_keycode_from_string(str(k))
		if code == KEY_NONE:
			bad.append(str(k))
			continue
		var ev := InputEventKey.new()
		ev.physical_keycode = code
		events.append(ev)
	if not bad.is_empty():
		return _err("Unknown key names: %s" % ", ".join(PackedStringArray(bad)))
	ProjectSettings.set_setting("input/" + action, {"deadzone": 0.5, "events": events})
	var err := ProjectSettings.save()
	if err != OK:
		return _err("Could not save project settings (code %d)." % err)
	return _ok({"message": "Added input action '%s' with %d key(s)." % [action, events.size()]})


# ---------------------------------------------------------------------------
# Undo/redo helpers (called through EditorUndoRedoManager)
# ---------------------------------------------------------------------------

func _begin_action(action_name: String) -> EditorUndoRedoManager:
	var ur := get_undo_redo()
	# Using the scene root as context keeps these actions in the scene's undo history.
	ur.create_action(action_name, UndoRedo.MERGE_DISABLE, EditorInterface.get_edited_scene_root())
	return ur


func _do_add_node(parent_node: Node, node: Node, root: Node) -> void:
	parent_node.add_child(node, true)
	_restore_owner(node, root)


func _undo_remove_node(parent_node: Node, node: Node, idx: int, root: Node) -> void:
	parent_node.add_child(node, true)
	parent_node.move_child(node, idx)
	_restore_owner(node, root)


func _do_reparent(node: Node, new_parent: Node, root: Node) -> void:
	node.reparent(new_parent)
	_restore_owner(node, root)


func _undo_reparent(node: Node, old_parent: Node, idx: int, root: Node) -> void:
	node.reparent(old_parent)
	old_parent.move_child(node, idx)
	_restore_owner(node, root)


## Re-own a node (and plain descendants) to the scene root. Children that belong to an
## instanced scene keep their own owner.
func _restore_owner(node: Node, root: Node) -> void:
	node.owner = root
	if node.scene_file_path.is_empty():
		for child in node.get_children():
			_restore_owner(child, root)


# ---------------------------------------------------------------------------
# Helpers & Type Conversions
# ---------------------------------------------------------------------------

func _rel_path(node: Node) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return ""
	return str(root.get_path_to(node))


## Resolve a node from a path string or {node_path}/{path} dictionary.
## With allow_fallback=false an explicit path is required (used by mutating commands);
## with true, an omitted path falls back to the editor selection, then the scene root.
func _find_target_node(target_info, allow_fallback: bool = true) -> Node:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null

	var path_str := ""
	var t := typeof(target_info)
	if t == TYPE_STRING or t == TYPE_NODE_PATH or t == TYPE_STRING_NAME:
		path_str = str(target_info)
	elif t == TYPE_DICTIONARY:
		path_str = str(target_info.get("node_path", target_info.get("path", "")))

	if not path_str.is_empty():
		if path_str == "." or path_str == root.name:
			return root
		var found := root.get_node_or_null(NodePath(path_str))
		if found == null and path_str.begins_with(str(root.name) + "/"):
			found = root.get_node_or_null(NodePath(path_str.trim_prefix(str(root.name) + "/")))
		return found

	if not allow_fallback:
		return null
	var selection := EditorInterface.get_selection().get_selected_nodes()
	if selection.size() > 0:
		return selection[0]
	return root


## Parent for new nodes: explicit "parent" if given, otherwise the scene root (never the selection).
func _resolve_parent(p: Dictionary) -> Node:
	if p.has("parent"):
		return _find_target_node(p["parent"], false)
	return EditorInterface.get_edited_scene_root()


func _property_type(obj: Object, prop_name: String) -> int:
	for prop in obj.get_property_list():
		if prop["name"] == prop_name:
			return int(prop["type"])
	return -1


## Set several properties from JSON values. Returns the names that could not be set.
func _apply_properties(obj: Object, props) -> Array:
	var skipped := []
	if typeof(props) != TYPE_DICTIONARY:
		return skipped
	for key in props.keys():
		var pname := str(key)
		var ptype := _property_type(obj, pname)
		if ptype == -1:
			skipped.append(pname)
			continue
		var raw = props[key]
		var conv = _convert_json_to_variant(raw, ptype)
		if conv == null and raw != null:
			skipped.append(pname)
			continue
		obj.set(pname, conv)
	return skipped


## Build a Resource from {"type": "RectangleShape2D", "properties": {"size": [32, 32]}}.
func _build_resource(spec: Dictionary) -> Resource:
	var rtype := str(spec.get("type", ""))
	if not ClassDB.class_exists(rtype) or not ClassDB.is_parent_class(rtype, "Resource") or not ClassDB.can_instantiate(rtype):
		return null
	var res := ClassDB.instantiate(rtype) as Resource
	_apply_properties(res, spec.get("properties", {}))
	return res


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
		TYPE_VECTOR4:
			if val is Array and val.size() >= 4:
				return Vector4(float(val[0]), float(val[1]), float(val[2]), float(val[3]))
		TYPE_RECT2:
			if val is Array and val.size() >= 4:
				return Rect2(float(val[0]), float(val[1]), float(val[2]), float(val[3]))
		TYPE_RECT2I:
			if val is Array and val.size() >= 4:
				return Rect2i(int(val[0]), int(val[1]), int(val[2]), int(val[3]))
		TYPE_TRANSFORM2D:
			if val is Array and val.size() >= 6:
				return Transform2D(
					Vector2(float(val[0]), float(val[1])),
					Vector2(float(val[2]), float(val[3])),
					Vector2(float(val[4]), float(val[5])))
		TYPE_TRANSFORM3D:
			if val is Array and val.size() >= 12:
				return Transform3D(
					Basis(
						Vector3(float(val[0]), float(val[1]), float(val[2])),
						Vector3(float(val[3]), float(val[4]), float(val[5])),
						Vector3(float(val[6]), float(val[7]), float(val[8]))),
					Vector3(float(val[9]), float(val[10]), float(val[11])))
		TYPE_COLOR:
			if val is Array and val.size() >= 3:
				var a := float(val[3]) if val.size() >= 4 else 1.0
				return Color(float(val[0]), float(val[1]), float(val[2]), a)
			elif val is String:
				return Color.from_string(val, Color.BLACK)
		TYPE_NODE_PATH:
			return NodePath(str(val))
		TYPE_INT:
			return int(val)
		TYPE_FLOAT:
			return float(val)
		TYPE_BOOL:
			if val is String:
				return val.to_lower() in ["true", "1", "yes", "on"]
			return bool(val)
		TYPE_STRING:
			return str(val)
		TYPE_STRING_NAME:
			return StringName(str(val))
		TYPE_ARRAY:
			if val is Array:
				return val
		TYPE_DICTIONARY:
			if val is Dictionary:
				return val
		TYPE_PACKED_STRING_ARRAY:
			if val is Array:
				var psa := PackedStringArray()
				for e in val:
					psa.append(str(e))
				return psa
		TYPE_PACKED_VECTOR2_ARRAY:
			if val is Array:
				var pva := PackedVector2Array()
				for e in val:
					if e is Array and e.size() >= 2:
						pva.append(Vector2(float(e[0]), float(e[1])))
				return pva
		TYPE_OBJECT:
			# Returns null on failure; callers treat null (with non-null input) as an error.
			if val == null:
				return null
			if val is String and val.begins_with("res://"):
				var rp := _resolve_safe_path(val)
				if not rp.is_empty() and ResourceLoader.exists(rp):
					return load(rp)
			elif val is Dictionary and val.has("type"):
				return _build_resource(val)
			return null

	if val is String:
		var parsed = str_to_var(val)
		if parsed != null:
			return parsed

	return val


func _variant_to_json_safe(v: Variant) -> Variant:
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return v
		TYPE_FLOAT:
			if is_inf(v) or is_nan(v):
				return str(v)
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
		TYPE_STRING_NAME: return "StringName"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR3I: return "Vector3i"
		TYPE_VECTOR4: return "Vector4"
		TYPE_RECT2: return "Rect2"
		TYPE_TRANSFORM2D: return "Transform2D"
		TYPE_TRANSFORM3D: return "Transform3D"
		TYPE_COLOR: return "Color"
		TYPE_NODE_PATH: return "NodePath"
		TYPE_OBJECT: return "Object"
		TYPE_ARRAY: return "Array"
		TYPE_DICTIONARY: return "Dictionary"
		_: return "Variant"


func _describe_node(node: Node, root: Node, depth: int, max_depth: int) -> Dictionary:
	var desc := {
		"name": str(node.name),
		"type": node.get_class(),
		"path": str(root.get_path_to(node)),
	}
	var scr = node.get_script()
	if scr != null and not str(scr.resource_path).is_empty():
		desc["script"] = scr.resource_path
	if depth > 0 and not node.scene_file_path.is_empty():
		desc["scene"] = node.scene_file_path
	if depth < max_depth and node.get_child_count() > 0:
		var children := []
		for child in node.get_children():
			children.append(_describe_node(child, root, depth + 1, max_depth))
		desc["children"] = children
	return desc


func _find_by_class(node: Node, cls: String) -> Node:
	if node == null:
		return null
	if node.get_class() == cls:
		return node
	for c in node.get_children():
		var r := _find_by_class(c, cls)
		if r != null:
			return r
	return null


# ---------------------------------------------------------------------------
# HTTP Response Helper
# ---------------------------------------------------------------------------

func _queue_response(conn: Dictionary, status_code: int, response_body: String) -> void:
	var reason := _http_reason(status_code)
	var body_bytes := response_body.to_utf8_buffer()

	var response := "HTTP/1.1 %d %s\r\n" % [status_code, reason]
	response += "Content-Type: application/json; charset=utf-8\r\n"
	response += "Content-Length: %d\r\n" % body_bytes.size()
	if not cors_origin.is_empty():
		response += "Access-Control-Allow-Origin: %s\r\n" % cors_origin
		response += "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
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

