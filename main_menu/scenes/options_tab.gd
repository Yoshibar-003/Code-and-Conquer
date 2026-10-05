extends Control

@onready var volume_slider: HSlider = $Panel/VBoxContainer/VolumeSlider
@onready var fullscreen_check: CheckButton = $Panel/VBoxContainer/FullscreenCheck
@onready var back_button: Button = $Panel/VBoxContainer/BackButton

func _ready() -> void:
	volume_slider.value = clamp(db_to_linear(AudioServer.get_bus_volume_db(0)), 0.0, 1.0)
	fullscreen_check.button_pressed = DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN

	if not volume_slider.value_changed.is_connected(_on_volume_changed):
		volume_slider.value_changed.connect(_on_volume_changed)
	if not fullscreen_check.toggled.is_connected(_on_fullscreen_toggled):
		fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	if not back_button.pressed.is_connected(hide):
		back_button.pressed.connect(hide)

func _on_volume_changed(value: float) -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(value))

func _on_fullscreen_toggled(enabled: bool) -> void:
	if enabled:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
