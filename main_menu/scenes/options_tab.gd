extends Control

const SettingsManagerScript := preload("res://config/settings_manager.gd")
const SETTINGS_PATH := SettingsManagerScript.SETTINGS_PATH

# Choice rows: key -> [row node name, button labels]. The window_mode label order
# must match SettingsManager's WINDOW_MODE_* constant values.
const CHOICE_ROW_DEFS := {
	"window_mode": ["WindowModeRow", ["Windowed", "Maximized", "Fullscreen"]],
	"ui_scale": ["UiScaleRow", ["Small", "Medium", "Large"]],
	"code_font_size": ["CodeFontSizeRow", ["Small", "Medium", "Large"]],
	"editor_theme": ["EditorThemeRow", ["Dark", "Light"]],
	"animation_speed": ["AnimationSpeedRow", ["Normal", "Fast"]],
}
const DEFAULT_CHOICE_INDEX := {
	"window_mode": SettingsManagerScript.WINDOW_MODE_WINDOWED,
	"ui_scale": 1,
	"code_font_size": 1,
	"editor_theme": 0,
	"animation_speed": 0,
	"default_language": 0,
}
const CHOICE_SELECTED_COLOR := Color(0.55, 0.85, 1)
const CHOICE_UNSELECTED_COLOR := Color(0.6, 0.65, 0.75)

@onready var volume_slider: HSlider = $Panel/ScrollContainer/VBoxContainer/VolumeSlider
@onready var music_slider: HSlider = $Panel/ScrollContainer/VBoxContainer/MusicSlider
@onready var sfx_slider: HSlider = $Panel/ScrollContainer/VBoxContainer/SfxSlider
@onready var grid_coordinates_check: CheckButton = $Panel/ScrollContainer/VBoxContainer/GridCoordinatesCheck
@onready var command_trail_check: CheckButton = $Panel/ScrollContainer/VBoxContainer/CommandTrailCheck
@onready var beginner_hints_check: CheckButton = $Panel/ScrollContainer/VBoxContainer/BeginnerHintsCheck
@onready var default_language_option: OptionButton = $Panel/ScrollContainer/VBoxContainer/DefaultLanguageOption
@onready var reset_button: Button = $Panel/ScrollContainer/VBoxContainer/ResetButton
@onready var back_button: Button = $Panel/ScrollContainer/VBoxContainer/BackButton

var _choice_index: Dictionary = DEFAULT_CHOICE_INDEX.duplicate()
var _choice_rows := {}


func _ready() -> void:
	_setup_choice_rows()
	_add_choices(default_language_option, ["Python", "C++"])
	_load_settings()

	if not volume_slider.value_changed.is_connected(_on_volume_changed):
		volume_slider.value_changed.connect(_on_volume_changed)
	if not music_slider.value_changed.is_connected(_on_preference_changed):
		music_slider.value_changed.connect(_on_preference_changed)
	if not sfx_slider.value_changed.is_connected(_on_preference_changed):
		sfx_slider.value_changed.connect(_on_preference_changed)
	if not default_language_option.item_selected.is_connected(_on_option_selected):
		default_language_option.item_selected.connect(_on_option_selected)
	for check in [grid_coordinates_check, command_trail_check, beginner_hints_check]:
		if not check.toggled.is_connected(_on_toggle_changed):
			check.toggled.connect(_on_toggle_changed)
	if not reset_button.pressed.is_connected(_on_reset_button_pressed):
		reset_button.pressed.connect(_on_reset_button_pressed)
	if not back_button.pressed.is_connected(hide):
		back_button.pressed.connect(hide)


# A user-requested mode that hasn't shown up in window_get_mode() yet.
# window_set_mode isn't instant; transitions can pass through intermediate
# modes (e.g. fullscreen -> maximized reports WINDOWED for a few frames), and
# without this, the sync below would revert the selection mid-transition.
var _pending_window_mode := -1
var _pending_window_mode_since := 0.0
const PENDING_WINDOW_MODE_TIMEOUT := 0.5


# Keeps the WINDOW MODE row in sync with the actual window state while the
# panel is open. The OS mode is the source of truth: this catches title-bar
# button clicks AND window_set_mode calls the OS ignored (the row would
# otherwise show a mode that was never applied).
func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	var index := _os_window_mode_index()
	if index < 0:
		return
	if _pending_window_mode >= 0:
		if index == _pending_window_mode:
			_pending_window_mode = -1
			return
		# Still waiting for the requested mode — unless it timed out, meaning the
		# OS ignored the request and we should sync to reality instead.
		if Time.get_ticks_msec() / 1000.0 - _pending_window_mode_since < PENDING_WINDOW_MODE_TIMEOUT:
			return
		_pending_window_mode = -1
	if _choice_index["window_mode"] == index:
		return
	_choice_index["window_mode"] = index
	_set_choice_selected("window_mode", index)
	var settings_manager := get_node_or_null("/root/SettingsManager")
	if settings_manager != null and settings_manager.has_method("persist_window_mode"):
		settings_manager.persist_window_mode(index)


func _os_window_mode_index() -> int:
	match DisplayServer.window_get_mode():
		DisplayServer.WINDOW_MODE_MAXIMIZED:
			return SettingsManagerScript.WINDOW_MODE_MAXIMIZED
		# Although we don't give option to set WINDOW_MODE_EXCLUSIVE_FULLSCREEN, something
		# else like the OS might've requested it, so handle it same as WINDOW_MODE_FULLSCREEN
		DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
			return SettingsManagerScript.WINDOW_MODE_FULLSCREEN
		DisplayServer.WINDOW_MODE_WINDOWED:
			return SettingsManagerScript.WINDOW_MODE_WINDOWED
	return -1

# Escape closes the options menu (same as the Back button). Uses _unhandled_input so an open
# dropdown list gets to consume Escape first and only closes itself.
func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event.is_action_pressed("ui_cancel"):
		hide()
		get_viewport().set_input_as_handled()


func _on_volume_changed(value: float) -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(value))
	_save_settings()


func _setup_choice_rows() -> void:
	var vbox := $Panel/ScrollContainer/VBoxContainer
	for key in CHOICE_ROW_DEFS:
		var def: Array = CHOICE_ROW_DEFS[key]
		var row := vbox.get_node(def[0]) as HBoxContainer
		if row == null:
			push_error("OptionsTab: missing choice row " + def[0])
			continue
		var buttons: Array[Button] = []
		for i in def[1].size():
			var button := Button.new()
			button.text = def[1][i]
			button.custom_minimum_size = Vector2(0, 44)
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			button.add_theme_font_size_override("font_size", 18)
			var index: int = i
			button.pressed.connect(func(): _on_choice_pressed(key, index))
			row.add_child(button)
			buttons.append(button)
		_choice_rows[key] = buttons
		_set_choice_selected(key, _choice_index[key])


func _on_choice_pressed(key: String, index: int) -> void:
	_choice_index[key] = index
	_set_choice_selected(key, index)
	if key == "window_mode":
		_request_window_mode(index)
	# _save_settings is the single writer for the options UI: it persists
	# window_mode and reloads SettingsManager.
	_save_settings()


func _set_choice_selected(key: String, index: int) -> void:
	var buttons: Array = _choice_rows.get(key, [])
	for i in buttons.size():
		var button: Button = buttons[i]
		if i == index:
			button.add_theme_color_override("font_color", CHOICE_SELECTED_COLOR)
			button.add_theme_color_override("font_hover_color", Color.WHITE)
		else:
			button.add_theme_color_override("font_color", CHOICE_UNSELECTED_COLOR)
			button.add_theme_color_override("font_hover_color", CHOICE_SELECTED_COLOR.lightened(0.2))


func _request_window_mode(mode: int) -> void:
	_pending_window_mode = mode
	_pending_window_mode_since = Time.get_ticks_msec() / 1000.0
	var settings_manager := get_node_or_null("/root/SettingsManager")
	if settings_manager != null and settings_manager.has_method("apply_window_mode"):
		settings_manager.apply_window_mode(mode)


func _load_settings() -> void:
	var config := ConfigFile.new()

	if config.load(SETTINGS_PATH) == OK:
		volume_slider.value = float(config.get_value("audio", "master_volume", 1.0))
		music_slider.value = float(config.get_value("audio", "music_volume", 1.0))
		sfx_slider.value = float(config.get_value("audio", "sfx_volume", 1.0))
		# SettingsManager owns the clamp + legacy-fullscreen fallback so a
		# corrupted config value can't desync the row from the applied mode.
		var settings_manager := get_node_or_null("/root/SettingsManager")
		if settings_manager != null and settings_manager.has_method("get_window_mode"):
			_choice_index["window_mode"] = settings_manager.get_window_mode()
		else:
			# Autoload missing (shouldn't happen): just clamp the raw value.
			_choice_index["window_mode"] = clampi(int(config.get_value("display", "window_mode",
				SettingsManagerScript.WINDOW_MODE_WINDOWED)), SettingsManagerScript.WINDOW_MODE_WINDOWED, SettingsManagerScript.WINDOW_MODE_FULLSCREEN)
		_choice_index["ui_scale"] = clampi(int(config.get_value("display", "ui_scale", 1)), 0, 2)
		_choice_index["code_font_size"] = clampi(int(config.get_value("editor", "font_size", 1)), 0, 2)
		_choice_index["editor_theme"] = clampi(int(config.get_value("editor", "theme", 0)), 0, 1)
		_choice_index["animation_speed"] = clampi(int(config.get_value("gameplay", "animation_speed", 0)), 0, 1)
		grid_coordinates_check.button_pressed = bool(config.get_value("learning", "show_grid_coordinates", false))
		command_trail_check.button_pressed = bool(config.get_value("learning", "show_command_trail", true))
		beginner_hints_check.button_pressed = bool(config.get_value("learning", "beginner_hints", true))
		_choice_index["default_language"] = clampi(int(config.get_value("editor", "default_language", 0)), 0, 1)
	else:
		volume_slider.value = 1.0
		music_slider.value = 1.0
		sfx_slider.value = 1.0
		for key in _choice_index:
			_choice_index[key] = DEFAULT_CHOICE_INDEX[key]
		grid_coordinates_check.button_pressed = false
		command_trail_check.button_pressed = true
		beginner_hints_check.button_pressed = true

	_refresh_choice_visuals()
	_apply_settings()


func _refresh_choice_visuals() -> void:
	for key in _choice_rows:
		_set_choice_selected(key, _choice_index[key])
	default_language_option.select(_choice_index["default_language"])


func _apply_settings() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(volume_slider.value))
	_set_bus_volume("Music", music_slider.value)
	_set_bus_volume("SFX", sfx_slider.value)


func _save_settings() -> void:
	# Merge onto the existing file so keys this panel doesn't own survive.
	# On unreadable/corrupt config, fall back to a fresh file; every known
	# key is written below anyway, so this repairs rather than truncates.
	var config := ConfigFile.new()
	var load_result := config.load(SETTINGS_PATH)
	if load_result != OK and load_result != ERR_FILE_NOT_FOUND:
		config = ConfigFile.new()
	config.set_value("audio", "master_volume", volume_slider.value)
	config.set_value("audio", "music_volume", music_slider.value)
	config.set_value("audio", "sfx_volume", sfx_slider.value)
	var window_mode := clampi(_choice_index["window_mode"], SettingsManagerScript.WINDOW_MODE_WINDOWED, SettingsManagerScript.WINDOW_MODE_FULLSCREEN)
	config.set_value("display", "window_mode", window_mode)
	config.set_value("display", "fullscreen", window_mode == SettingsManagerScript.WINDOW_MODE_FULLSCREEN)
	config.set_value("display", "ui_scale", _choice_index["ui_scale"])
	config.set_value("editor", "font_size", _choice_index["code_font_size"])
	config.set_value("editor", "theme", _choice_index["editor_theme"])
	config.set_value("gameplay", "animation_speed", _choice_index["animation_speed"])
	config.set_value("learning", "show_grid_coordinates", grid_coordinates_check.button_pressed)
	config.set_value("learning", "show_command_trail", command_trail_check.button_pressed)
	config.set_value("learning", "beginner_hints", beginner_hints_check.button_pressed)
	config.set_value("editor", "default_language", _choice_index["default_language"])
	var save_result := config.save(SETTINGS_PATH)
	if save_result != OK:
		push_error("OptionsTab: could not write settings.cfg (%s)" % error_string(save_result))
	var settings_manager := get_node_or_null("/root/SettingsManager")
	if settings_manager != null:
		settings_manager.reload_settings()


func _add_choices(option: OptionButton, choices: Array[String]) -> void:
	option.clear()
	for choice in choices:
		option.add_item(choice)


func _on_preference_changed(_value: float) -> void:
	_apply_settings()
	_save_settings()


func _set_bus_volume(bus_name: String, value: float) -> void:
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index >= 0:
		AudioServer.set_bus_volume_db(bus_index, linear_to_db(value))


func _on_option_selected(_index: int) -> void:
	_choice_index["default_language"] = _index
	_save_settings()


func _on_toggle_changed(_enabled: bool) -> void:
	_save_settings()


func _on_reset_button_pressed() -> void:
	volume_slider.value = 1.0
	music_slider.value = 1.0
	sfx_slider.value = 1.0
	for key in _choice_index:
		_choice_index[key] = DEFAULT_CHOICE_INDEX[key]
	_request_window_mode(SettingsManagerScript.WINDOW_MODE_WINDOWED)
	grid_coordinates_check.button_pressed = false
	command_trail_check.button_pressed = true
	beginner_hints_check.button_pressed = true
	_refresh_choice_visuals()
	_apply_settings()
	_save_settings()
