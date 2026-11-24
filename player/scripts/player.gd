extends Node2D

signal lose_triggered(reason: String)
signal move_finished()

# === player state ===
# Array ordered to exactly match your rotation_step integers
# 0 = East, 1 = South, 2 = West, 3 = North
const DIRS = ["east", "south", "west", "north"]
# logical grid position + facing direction
var grid_x: int = 1
var grid_y: int = 1
var facing: String = "north"
var carried_object: Dictionary = {}
var _has_lost: bool = false
var current_tween: Tween
var _move_in_progress: bool = false
var _active_tween_duration: float = 0.0
var _active_tween_start_msec: int = 0
var _active_tween_is_fall: bool = false
var _move_from_x: int = 0
var _move_from_y: int = 0
var _move_duration: float = 0.0
var _move_start_msec: int = 0
# Pixel-space endpoints of the active move segment in the current rotation
# frame. Used to recover true tween progress on rotation retarget; wall-clock
# progress overstates it because the world rebuild stalls frames while
# Time.get_ticks_msec() keeps running.
var _move_pixel_from := Vector2.ZERO
var _move_pixel_to := Vector2.ZERO

func _ready() -> void:
	pass


func _exit_tree() -> void:
	# Kill any in-flight movement tween so a stale animation cannot keep
	# modifying this player while the level is being torn down.
	if current_tween != null and is_instance_valid(current_tween):
		current_tween.kill()
	current_tween = null
	

func update_animation(is_running: bool = false) -> void:
	var world = _get_world()
	var camera_offset = 0
	
	# Fetch the current rotation step from the world
	if world != null and world.has_method("get_rotation_step"):
		camera_offset = world.get_rotation_step()
		
	# 1. Find the player's logical direction index (0 to 3)
	var current_idx = DIRS.find(facing)
	
	# 2. Apply the camera offset. Modulo (%) 4 safely wraps it around.
	var visual_idx = (current_idx + camera_offset) % 4
	var visual_facing = DIRS[visual_idx]
	
	# 3. Construct and play the animation
	var prefix = "Run_" if is_running else "Idle_"
	var suffix = ""
	
	match visual_facing:
		"north": suffix = "N"
		"east":  suffix = "E"
		"south": suffix = "S"
		"west":  suffix = "W"
		
	$AnimatedSprite2D.play(prefix + suffix)

	# Notify compass of the player's logical direction index
	EventManager.player_facing_changed.emit(current_idx)
	

## Initialize player at proper location and face direction
func initialize_from_level(robot_data: Dictionary, world_pos: Vector2, is_rotating: bool) -> void:
	var tween_running := current_tween != null and is_instance_valid(current_tween) and current_tween.is_running()

	# During camera rotation, an in-flight move tween must be retargeted to the
	# rotated destination instead of killed (or move_forward() would never emit
	# move_finished and the workstation would treat the run as stuck).
	if is_rotating and tween_running:
		_retarget_active_tween(world_pos)
	else:
		if tween_running:
			current_tween.kill()
		current_tween = null
		position = world_pos
		_active_tween_duration = 0.0
		_active_tween_is_fall = false
		_move_duration = 0.0

	if not is_rotating:
		modulate.a = 1.0
		# BRAND NEW LEVEL: Reset logical variables
		_has_lost = false
		carried_object = {}
		var robot_objects = robot_data.get("objects", {})
		if robot_objects is Dictionary:
			carried_object = robot_objects.duplicate()
		grid_x = robot_data.get("x", 1)
		grid_y = robot_data.get("y", 1)
		_move_in_progress = false

		var start_face: int = robot_data.get("_orientation", 1)
		facing = DIRS[start_face]

	# Whether brand new or just rotating, update the visual sprite
	update_animation(_move_in_progress)

## Check if we are inside a parent and gives node acces
func _get_world() -> Node:
	var world_root = get_parent()
	if world_root == null:
		return null
	return world_root.get_parent()

# ========= Movement =========
## Advances the player one step to where its facing
func move_forward(duration: float = 0.5) -> void:
	if _has_lost:
		move_finished.emit()
		return
	var world = _get_world()
	var next_x = grid_x
	var next_y = grid_y
	
	# Determine its next grid position logically
	match facing:
		"east": next_x += 1
		"west": next_x -= 1
		"north": next_y += 1
		"south": next_y -= 1

	# Lose Condition ----------------------------------------
	# LOSE: on attempted move through a wall edge
	if world.has_method("is_move_blocked"):
		if world.is_move_blocked(grid_x, grid_y, facing):
			_trigger_lose("You lose: attempted to move through a wall.")
			move_finished.emit()
			return
	# -------------------------------------------------------

	_move_from_x = grid_x
	_move_from_y = grid_y
	grid_x = next_x
	grid_y = next_y
	_move_in_progress = true

	# Play running animation
	update_animation(true)

	# Obtain next logical coordinate position and move
	if world.has_method("player_grid_position"):
		var target_pos: Vector2 = world.player_grid_position(grid_x, grid_y)
		_start_move_tween(target_pos, duration)
		await _wait_seconds(duration)

	_move_in_progress = false

	# Stop running animation
	update_animation(false)
	if world.is_void(grid_x, grid_y):
		var fall_duration := maxf(duration, 0.15)
		_start_fall_tween(fall_duration)
		await _wait_seconds(fall_duration)
		_trigger_lose("You fell into the void. Watch for missing floor tiles!")

	move_finished.emit()


func _start_move_tween(target_pos: Vector2, duration: float) -> void:
	var world = _get_world()
	if world != null and world.has_method("player_grid_position"):
		_move_pixel_from = world.player_grid_position(_move_from_x, _move_from_y)
	else:
		_move_pixel_from = position
	_move_pixel_to = target_pos
	current_tween = create_tween()
	current_tween.tween_property(self, "position", target_pos, duration)
	_move_duration = duration
	_move_start_msec = Time.get_ticks_msec()
	_active_tween_is_fall = false


func _start_fall_tween(duration: float) -> void:
	current_tween = create_tween()
	current_tween.set_parallel(true)
	current_tween.tween_property(self, "modulate:a", 0.0, duration)
	current_tween.tween_property(self, "position:y", position.y + 80.0, duration)
	_active_tween_duration = duration
	_active_tween_start_msec = Time.get_ticks_msec()
	_active_tween_is_fall = true


func _wait_seconds(seconds: float) -> void:
	if seconds <= 0.0:
		return
	await get_tree().create_timer(seconds).timeout


func _active_tween_remaining() -> float:
	if _active_tween_duration <= 0.0:
		return 0.0
	var elapsed := float(Time.get_ticks_msec() - _active_tween_start_msec) / 1000.0
	return maxf(0.0, _active_tween_duration - elapsed)


func _move_elapsed() -> float:
	return float(Time.get_ticks_msec() - _move_start_msec) / 1000.0


func _move_remaining() -> float:
	return maxf(0.0, _move_duration - _move_elapsed())


func _move_progress() -> float:
	if _move_duration <= 0.0:
		return 1.0
	# Report visual progress along the pixel segment, not wall-clock elapsed:
	# synchronous world rebuilds stall frames while the clock keeps running,
	# so wall-clock progress would jump ahead of the tween's actual position.
	var segment := _move_pixel_to - _move_pixel_from
	var segment_len_sq := segment.length_squared()
	if segment_len_sq <= 0.0:
		return clampf(_move_elapsed() / _move_duration, 0.0, 1.0)
	return clampf((position - _move_pixel_from).dot(segment) / segment_len_sq, 0.0, 1.0)


func _retarget_active_tween(target_pos: Vector2) -> void:
	var was_fall := _active_tween_is_fall

	if current_tween != null and is_instance_valid(current_tween):
		current_tween.kill()
	current_tween = null

	if was_fall:
		# The void fall is terminal; snap to the cell and restart the fade/drop
		# for whatever time remains so the lose sequence still plays.
		var fall_remaining := _active_tween_remaining()
		position = target_pos
		_move_in_progress = false
		if fall_remaining > 0.0:
			_start_fall_tween(fall_remaining)
		else:
			_active_tween_duration = 0.0
			_active_tween_is_fall = false
		return

	# Preserve the in-between position: interpolate between the rotated
	# positions of the move's start and destination cells, then keep
	# animating to the destination over the remaining move time.
	# Progress comes from the player's actual pixel position on the stored
	# segment, not the wall clock; the synchronous world rebuild stalls
	# frames, so _move_progress() would jump ahead of the visible tween.
	var remaining := _move_remaining()
	var progress := _move_progress()
	var from_pos := target_pos
	var world = _get_world()
	if world != null and world.has_method("player_grid_position"):
		from_pos = world.player_grid_position(_move_from_x, _move_from_y)
	position = from_pos.lerp(target_pos, progress)
	_move_pixel_from = from_pos
	_move_pixel_to = target_pos

	if remaining <= 0.0:
		position = target_pos
		_active_tween_is_fall = false
		return

	current_tween = create_tween()
	current_tween.tween_property(self, "position", target_pos, remaining)


func _trigger_lose(reason: String) -> void:
	if _has_lost:
		return
	_has_lost = true
	emit_signal("lose_triggered", reason)


# === turning ===
# just changes facing for now
# later could also rotate sprite/marker visually if desired
func turn_left() -> void:
	var current_idx = DIRS.find(facing)
	# -1 goes counter-clockwise. Add 4 before modulo to prevent negative indexes.
	var new_idx = (current_idx - 1 + 4) % 4 
	facing = DIRS[new_idx]
	
	update_animation() # Updates the Idle animation automatically


# === object interaction stubs ===
# world behavior for objects is still placeholder-ish,
# so for now the robot just asks the world if it knows how to handle it
func pick_object() -> void:
	var world = _get_world()
	if world == null:
		return

	if world.has_method("remove_object_at"):
		var obj = world.remove_object_at(grid_x, grid_y)
		if obj != "":
			if not carried_object.has(obj):
				carried_object[obj] = 0
			carried_object[obj] += 1


func put_object() -> void:
	var world = _get_world()
	if world == null:
		return

	if carried_object.is_empty():
		return

	if world.has_method("place_object_at"):
		var obj_name = carried_object.keys()[0]
		world.place_object_at(grid_x, grid_y, obj_name)
		carried_object[obj_name] -= 1
		if carried_object[obj_name] <= 0:
			carried_object.erase(obj_name)
