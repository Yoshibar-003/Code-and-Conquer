extends Node

const SETTINGS_PATH := "user://settings.cfg"

# display/window_mode values — must match the option order in options_tab.gd
const WINDOW_MODE_WINDOWED := 0
const WINDOW_MODE_MAXIMIZED := 1
const WINDOW_MODE_FULLSCREEN := 2

var _config := ConfigFile.new()


func _ready() -> void:
	reload_settings()
	_apply_window_mode_once()


func reload_settings() -> void:
	_config = ConfigFile.new()
	_config.load(SETTINGS_PATH)
	_apply_global_settings()


func get_setting(section: String, key: String, fallback):
	return _config.get_value(section, key, fallback)


# Window mode is a startup setting: applied once here, never on reload, so saving
# unrelated options can't clobber a manually maximized/restored window.
func _apply_window_mode_once() -> void:
	apply_window_mode(get_window_mode())


func get_window_mode() -> int:
	if _config.has_section_key("display", "window_mode"):
		return clampi(int(_config.get_value("display", "window_mode", WINDOW_MODE_WINDOWED)), 0, 2)
	# legacy configs only stored a fullscreen bool
	if bool(_config.get_value("display", "fullscreen", false)):
		return WINDOW_MODE_FULLSCREEN
	return WINDOW_MODE_WINDOWED


# Convenience wrapper: persist + apply in one call.
# Note: Currently not called by anything. The options panel calls
# apply_window_mode()/persist_window_mode() separately so it can be the single
# writer of settings.cfg. Kept in case a caller is made that wants both.
func set_window_mode(mode: int) -> void:
	mode = clampi(mode, 0, 2)
	persist_window_mode(mode)
	apply_window_mode(mode)


# Changes the actual window only, no settings.cfg write. For callers (like the
# options panel) that persist the value themselves.
func apply_window_mode(mode: int) -> void:
	DisplayServer.window_set_mode(_window_mode_to_display(clampi(mode, 0, 2)))


# Writes the mode to settings.cfg without touching the actual window. Used when
# syncing FROM the OS state; re-issuing window_set_mode there would poke the
# window for a mode it already has. Only the two keys this owns are merge-saved
# so unrelated keys written since the last reload can't be clobbered; _config is
# still updated in memory so get_window_mode() stays correct.
func persist_window_mode(mode: int) -> void:
	mode = clampi(mode, 0, 2)
	var on_disk := ConfigFile.new()
	var load_result := on_disk.load(SETTINGS_PATH)
	if load_result != OK and load_result != ERR_FILE_NOT_FOUND:
		# Malformed/unreadable config: saving now would truncate every other
		# preference to just the two keys below. So leave the file untouched.
		push_error("SettingsManager: could not read settings.cfg (%s); window_mode not persisted"
			% error_string(load_result))
		return
	on_disk.set_value("display", "window_mode", mode)
	on_disk.set_value("display", "fullscreen", mode == WINDOW_MODE_FULLSCREEN)
	var save_result := on_disk.save(SETTINGS_PATH)
	if save_result != OK:
		push_error("SettingsManager: could not write settings.cfg (%s)"
			% error_string(save_result))
		return
	_config.set_value("display", "window_mode", mode)
	# keep the legacy key in sync for anything still reading it
	_config.set_value("display", "fullscreen", mode == WINDOW_MODE_FULLSCREEN)


func _window_mode_to_display(mode: int) -> DisplayServer.WindowMode:
	match mode:
		WINDOW_MODE_MAXIMIZED:
			return DisplayServer.WINDOW_MODE_MAXIMIZED
		WINDOW_MODE_FULLSCREEN:
			return DisplayServer.WINDOW_MODE_FULLSCREEN
	return DisplayServer.WINDOW_MODE_WINDOWED


func _apply_global_settings() -> void:
	var ui_scale_index := clampi(int(get_setting("display", "ui_scale", 1)), 0, 2)
	var ui_scales := [0.85, 1.0, 1.15]
	get_window().content_scale_factor = ui_scales[ui_scale_index]
