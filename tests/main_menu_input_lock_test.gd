extends SceneTree

const MENU_SCENE := "res://main_menu/scenes/main_menu.tscn"
const TEST_LEVEL := "res://data/campaign_levels/campaign/01_first_steps.json"

var failures := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run_tests")

func _menu_buttons(menu) -> Array:
	var buttons: Array = []
	var container = menu.get_node_or_null("MenuBG/ButtonsContainer")
	if container != null:
		for child in container.get_children():
			if child is BaseButton:
				buttons.append(child)
	return buttons

func _assert_locked(menu, label: String) -> void:
	check(menu._input_locked, label + ": input should be locked")
	for button in _menu_buttons(menu):
		check(button.disabled, label + ": menu button should be disabled")
	check(menu.popup_play_button.disabled, label + ": play button should be disabled")
	check(menu.level_dropdown.disabled, label + ": level dropdown should be disabled")
	check(not menu.level_popup.visible, label + ": level popup should be hidden")
	check(not menu.options_popup.visible, label + ": options popup should be hidden")
	check(not menu.level_file_dialog.visible, label + ": file dialog should be hidden")
	check(not menu.campaign_menu.visible, label + ": campaign menu should be hidden")

func run_tests() -> void:
	# near-zero time scale stretches the handlers' 2s/2.2s SceneTreeTimers so
	# they cannot fire (quit / scene change) before this test reports its result
	Engine.time_scale = 0.0001

	# QUIT locks the whole menu during its exit delay
	var quit_menu = load(MENU_SCENE).instantiate()
	root.add_child(quit_menu)
	await process_frame
	check(not quit_menu._input_locked, "Menu should start unlocked")
	# open every panel first so the lock's hide() calls are actually exercised
	quit_menu._on_button_start_pressed()
	quit_menu._open_custom_worlds()
	quit_menu._on_options_button_pressed()
	# FileDialog is exclusive by default and conflicts with the exclusive
	# LevelSelectPopup; relax it so both can be open for this test
	quit_menu.level_file_dialog.exclusive = false
	quit_menu.level_file_dialog.popup_centered_ratio(0.5)
	check(quit_menu.campaign_menu.visible, "Campaign menu should open before QUIT")
	check(quit_menu.level_popup.visible, "Level popup should open before QUIT")
	check(quit_menu.options_popup.visible, "Options tab should open before QUIT")
	check(quit_menu.level_file_dialog.visible, "File dialog should open before QUIT")
	quit_menu._on_quit_button_pressed()
	_assert_locked(quit_menu, "After QUIT")
	# Guarded handlers must no-op while locked
	quit_menu._on_button_start_pressed()
	quit_menu._open_custom_worlds()
	quit_menu._on_level_editor_button_pressed()
	quit_menu._on_options_button_pressed()
	quit_menu._on_upload_level_button_pressed()
	quit_menu._on_quit_button_pressed()
	check(not quit_menu.campaign_menu.visible, "Start must not reopen campaign while locked")
	_assert_locked(quit_menu, "After stray handler calls")

	# PLAY locks the menu during the load fade and rejects re-entry,
	# including a stray QUIT during the fade
	var play_menu = load(MENU_SCENE).instantiate()
	root.add_child(play_menu)
	await process_frame
	# realistic case: the level popup is open when PLAY is pressed;
	# opening it repopulates the dropdown, which clears SelectedLevel.path,
	# so the selection must be made afterwards like a real user would
	play_menu._open_custom_worlds()
	check(play_menu.level_popup.visible, "Level popup should open before PLAY")
	root.get_node("SelectedLevel").path = TEST_LEVEL
	play_menu._update_play_button()
	check(not play_menu.popup_play_button.disabled, "Play button should enable for a valid level")
	play_menu._on_play_button_pressed()
	_assert_locked(play_menu, "After PLAY")
	play_menu._on_play_button_pressed()
	play_menu._on_quit_button_pressed()
	check(play_menu._input_locked, "Input should stay locked after stray handler calls")

	quit_menu.queue_free()
	play_menu.queue_free()
	# give the audio server a few frames to release streams held by the
	# freed menus' players before the process exits
	for i in range(10):
		await process_frame

	Engine.time_scale = 1.0
	print("MAIN MENU INPUT LOCK TESTS: %d failures" % failures)
	quit(0 if failures == 0 else 1)
