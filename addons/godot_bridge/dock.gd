@tool
extends PanelContainer
# res://addons/godot_bridge/dock.gd

var bridge  # reference to the EditorPlugin instance (godot_bridge/plugin.gd)

var bind_edit: LineEdit
var port_edit: LineEdit
var token_edit: LineEdit
var status_label: Label
var toggle_button: Button
var command_checks: Dictionary = {}

const READ_ONLY_COMMANDS = [
	"ping",
	"get_commands",
	"get_scene_tree",
	"get_selected_nodes",
	"get_node_properties",
	"get_node_signals",
	"read_file",
	"list_dir",
	"get_open_script"
]

# Anything in plugin.gd's command_enabled that is not listed above is shown here
# automatically, so new commands never go missing from the dock again.
const MUTATING_COMMANDS = [
	"write_file",
	"spawn_node",
	"spawn_packed_scene",
	"remove_node",
	"reparent_node",
	"set_node_property",
	"connect_signal",
	"save_scene",
	"open_scene",
	"run_project",
	"stop_project"
]


func _ready() -> void:
	_build_ui()


func _mutating_commands() -> Array:
	var result: Array = MUTATING_COMMANDS.duplicate()
	if bridge != null:
		for key in bridge.command_enabled.keys():
			if not READ_ONLY_COMMANDS.has(key) and not result.has(key):
				result.append(key)
	return result


func _build_ui() -> void:
	custom_minimum_size = Vector2(300, 460)

	var scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	var title = Label.new()
	title.text = "Godot Bridge (Open WebUI)"
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	vbox.add_child(HSeparator.new())

	var bind_row = HBoxContainer.new()
	vbox.add_child(bind_row)
	var bind_label = Label.new()
	bind_label.text = "Bind:"
	bind_label.custom_minimum_size = Vector2(60, 0)
	bind_row.add_child(bind_label)
	bind_edit = LineEdit.new()
	bind_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bind_row.add_child(bind_edit)

	var port_row = HBoxContainer.new()
	vbox.add_child(port_row)
	var port_label = Label.new()
	port_label.text = "Port:"
	port_label.custom_minimum_size = Vector2(60, 0)
	port_row.add_child(port_label)
	port_edit = LineEdit.new()
	port_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	port_row.add_child(port_edit)

	var warn = Label.new()
	warn.text = "Binding to anything other than 127.0.0.1 exposes this to your network."
	warn.autowrap_mode = TextServer.AUTOWRAP_WORD
	warn.add_theme_color_override("font_color", Color(1, 0.65, 0.2))
	vbox.add_child(warn)

	var token_row = HBoxContainer.new()
	vbox.add_child(token_row)
	var token_label = Label.new()
	token_label.text = "Token:"
	token_label.custom_minimum_size = Vector2(60, 0)
	token_row.add_child(token_label)
	token_edit = LineEdit.new()
	token_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	token_row.add_child(token_edit)
	var gen_btn = Button.new()
	gen_btn.text = "Generate"
	gen_btn.pressed.connect(_on_generate_token)
	token_row.add_child(gen_btn)

	vbox.add_child(HSeparator.new())

	var commands_label = Label.new()
	commands_label.text = "Read-only commands"
	vbox.add_child(commands_label)

	for key in READ_ONLY_COMMANDS:
		var cb = CheckBox.new()
		cb.text = key
		vbox.add_child(cb)
		command_checks[key] = cb

	var danger_label = Label.new()
	danger_label.text = "Mutating commands"
	danger_label.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
	vbox.add_child(danger_label)

	for key in _mutating_commands():
		var cb2 = CheckBox.new()
		cb2.text = key
		vbox.add_child(cb2)
		command_checks[key] = cb2

	var save_btn = Button.new()
	save_btn.text = "Save Settings"
	save_btn.pressed.connect(_on_save)
	vbox.add_child(save_btn)

	vbox.add_child(HSeparator.new())

	toggle_button = Button.new()
	toggle_button.text = "Start Server"
	toggle_button.pressed.connect(_on_toggle)
	vbox.add_child(toggle_button)

	status_label = Label.new()
	status_label.text = "Stopped."
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(status_label)


func refresh() -> void:
	if bridge == null:
		return
	bind_edit.text = bridge.bind_address
	port_edit.text = str(bridge.port)
	token_edit.text = bridge.auth_token
	for key in command_checks.keys():
		command_checks[key].button_pressed = bridge.command_enabled.get(key, false)
	_update_status()


func _on_generate_token() -> void:
	if bridge == null:
		return
	token_edit.text = bridge.generate_token()


func _on_save() -> void:
	if bridge == null:
		return
	bridge.bind_address = bind_edit.text.strip_edges()
	bridge.port = int(port_edit.text.strip_edges())
	bridge.auth_token = token_edit.text.strip_edges()
	for key in command_checks.keys():
		bridge.command_enabled[key] = command_checks[key].button_pressed
	bridge.save_settings()

	if bridge.is_running:
		var result_msg = bridge.start_server()
		status_label.text = result_msg
		_update_status(result_msg)
	else:
		_update_status()


func _on_toggle() -> void:
	if bridge == null:
		return
	if bridge.is_running:
		bridge.stop_server()
		_update_status("Stopped.")
	else:
		var result_msg = bridge.start_server()
		_update_status(result_msg)


func _update_status(override_msg: String = "") -> void:
	if bridge == null:
		return

	if bridge.is_running:
		toggle_button.text = "Stop Server"
		status_label.text = override_msg if not override_msg.is_empty() else "Listening on %s:%d" % [bridge.bind_address, bridge.port]
	else:
		toggle_button.text = "Start Server"
		status_label.text = override_msg if not override_msg.is_empty() else "Stopped."
