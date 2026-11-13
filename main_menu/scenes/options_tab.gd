extends Control

const SETTINGS_PATH := "user://settings.cfg"
const SettingsManagerScript := preload("res://config/settings_manager.gd")

@onready var volume_slider: HSlider = $Panel/ScrollContainer/VBoxContainer/VolumeSlider
@onready var music_slider: HSlider = $Panel/ScrollContainer/VBoxContainer/MusicSlider
@onready var sfx_slider: HSlider = $Panel/ScrollContainer/VBoxContainer/SfxSlider
@onready var window_mode_option: OptionButton = $Panel/ScrollContainer/VBoxContainer/WindowModeOption
@onready var ui_scale_option: OptionButton = $Panel/ScrollContainer/VBoxContainer/UiScaleOption
@onready var code_font_size_option: OptionButton = $Panel/ScrollContainer/VBoxContainer/CodeFontSizeOption
@onready var editor_theme_option: OptionButton = $Panel/ScrollContainer/VBoxContainer/EditorThemeOption
@onready var animation_speed_option: OptionButton = $Panel/ScrollContainer/VBoxContainer/AnimationSpeedOption
@onready var grid_coordinates_check: CheckButton = $Panel/ScrollContainer/VBoxContainer/GridCoordinatesCheck
@onready var command_trail_check: CheckButton = $Panel/ScrollContainer/VBoxContainer/CommandTrailCheck
@onready var beginner_hints_check: CheckButton = $Panel/ScrollContainer/VBoxContainer/BeginnerHintsCheck
@onready var default_language_option: OptionButton = $Panel/ScrollContainer/VBoxContainer/DefaultLanguageOption
@onready var reset_button: Button = $Panel/ScrollContainer/VBoxContainer/ResetButton
@onready var back_button: Button = $Panel/ScrollContainer/VBoxContainer/BackButton

func _ready() -> void:
	_populate_choice_lists()
	_load_settings()

	if not volume_slider.value_changed.is_connected(_on_volume_changed):
		volume_slider.value_changed.connect(_on_volume_changed)
	if not window_mode_option.item_selected.is_connected(_on_window_mode_selected):
		window_mode_option.item_selected.connect(_on_window_mode_selected)
	if not music_slider.value_changed.is_connected(_on_preference_changed):
		music_slider.value_changed.connect(_on_preference_changed)
	if not sfx_slider.value_changed.is_connected(_on_preference_changed):
		sfx_slider.value_changed.connect(_on_preference_changed)
	for option in [ui_scale_option, code_font_size_option, editor_theme_option, animation_speed_option, default_language_option]:
		if not option.item_selected.is_connected(_on_option_selected):
			option.item_selected.connect(_on_option_selected)
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
# without this, the sync below would revert the dropdown mid-transition.
var _pending_window_mode := -1
var _pending_window_mode_since := 0.0
const PENDING_WINDOW_MODE_TIMEOUT := 0.5


# Keeps the WINDOW MODE dropdown in sync with the actual window state while the
# panel is open. The OS mode is the source of truth: this catches title-bar
# button clicks AND window_set_mode calls the OS ignored (dropdown would
# otherwise show a mode that was never applied). select() doesn't emit
# item_selected, so this can't retrigger _on_window_mode_selected.
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
	if window_mode_option.selected == index:
		return
	window_mode_option.select(index)
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

# Applies the window mode immediately and persists it. Window mode is also applied
# once at startup by SettingsManager; nothing here should re-apply it on scene load.
func _on_window_mode_selected(index: int) -> void:
	_request_window_mode(index)
	# _save_settings is the single writer for the options UI: it persists
	# window_mode and reloads SettingsManager.
	_save_settings()


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
		# corrupted config value can't desync the dropdown from the applied mode.
		var settings_manager := get_node_or_null("/root/SettingsManager")
		if settings_manager != null and settings_manager.has_method("get_window_mode"):
			window_mode_option.select(settings_manager.get_window_mode())
		else:
			window_mode_option.select(clampi(int(config.get_value("display", "window_mode",
				SettingsManagerScript.WINDOW_MODE_FULLSCREEN if bool(config.get_value("display", "fullscreen", false))
				else SettingsManagerScript.WINDOW_MODE_WINDOWED)), SettingsManagerScript.WINDOW_MODE_WINDOWED, SettingsManagerScript.WINDOW_MODE_FULLSCREEN))
		ui_scale_option.select(int(config.get_value("display", "ui_scale", 1)))
		code_font_size_option.select(int(config.get_value("editor", "font_size", 1)))
		editor_theme_option.select(int(config.get_value("editor", "theme", 0)))
		animation_speed_option.select(int(config.get_value("gameplay", "animation_speed", 0)))
		grid_coordinates_check.button_pressed = bool(config.get_value("learning", "show_grid_coordinates", false))
		command_trail_check.button_pressed = bool(config.get_value("learning", "show_command_trail", true))
		beginner_hints_check.button_pressed = bool(config.get_value("learning", "beginner_hints", true))
		default_language_option.select(int(config.get_value("editor", "default_language", 0)))
	else:
		volume_slider.value = 1.0
		music_slider.value = 1.0
		sfx_slider.value = 1.0
		window_mode_option.select(SettingsManagerScript.WINDOW_MODE_WINDOWED)
		ui_scale_option.select(1)
		code_font_size_option.select(1)
		editor_theme_option.select(0)
		animation_speed_option.select(0)
		grid_coordinates_check.button_pressed = false
		command_trail_check.button_pressed = true
		beginner_hints_check.button_pressed = true
		default_language_option.select(0)

	_apply_settings()


func _apply_settings() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(volume_slider.value))
	_set_bus_volume("Music", music_slider.value)
	_set_bus_volume("SFX", sfx_slider.value)


func _save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("audio", "master_volume", volume_slider.value)
	config.set_value("audio", "music_volume", music_slider.value)
	config.set_value("audio", "sfx_volume", sfx_slider.value)
	var window_mode := clampi(window_mode_option.selected, SettingsManagerScript.WINDOW_MODE_WINDOWED, SettingsManagerScript.WINDOW_MODE_FULLSCREEN)
	config.set_value("display", "window_mode", window_mode)
	config.set_value("display", "fullscreen", window_mode == SettingsManagerScript.WINDOW_MODE_FULLSCREEN)
	config.set_value("display", "ui_scale", ui_scale_option.selected)
	config.set_value("editor", "font_size", code_font_size_option.selected)
	config.set_value("editor", "theme", editor_theme_option.selected)
	config.set_value("gameplay", "animation_speed", animation_speed_option.selected)
	config.set_value("learning", "show_grid_coordinates", grid_coordinates_check.button_pressed)
	config.set_value("learning", "show_command_trail", command_trail_check.button_pressed)
	config.set_value("learning", "beginner_hints", beginner_hints_check.button_pressed)
	config.set_value("editor", "default_language", default_language_option.selected)
	config.save(SETTINGS_PATH)
	var settings_manager := get_node_or_null("/root/SettingsManager")
	if settings_manager != null:
		settings_manager.reload_settings()


func _populate_choice_lists() -> void:
	# Item order must match SettingsManager's WINDOW_MODE_* constant values.
	_add_choices(window_mode_option, ["Windowed", "Maximized", "Fullscreen"])
	_add_choices(ui_scale_option, ["Small", "Medium", "Large"])
	_add_choices(code_font_size_option, ["Small", "Medium", "Large"])
	_add_choices(editor_theme_option, ["Dark", "Light"])
	_add_choices(animation_speed_option, ["Normal", "Fast"])
	_add_choices(default_language_option, ["Python", "C++"])


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
	_save_settings()


func _on_toggle_changed(_enabled: bool) -> void:
	_save_settings()


func _on_reset_button_pressed() -> void:
	volume_slider.value = 1.0
	music_slider.value = 1.0
	sfx_slider.value = 1.0
	window_mode_option.select(SettingsManagerScript.WINDOW_MODE_WINDOWED)
	_request_window_mode(SettingsManagerScript.WINDOW_MODE_WINDOWED)
	ui_scale_option.select(1)
	code_font_size_option.select(1)
	editor_theme_option.select(0)
	animation_speed_option.select(0)
	grid_coordinates_check.button_pressed = false
	command_trail_check.button_pressed = true
	beginner_hints_check.button_pressed = true
	default_language_option.select(0)
	_apply_settings()
	_save_settings()
