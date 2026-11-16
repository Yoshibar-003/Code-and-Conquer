# flat_grid_view.gd
# To whom it may concern: This script draws a flat top-down 2D version of the level.
# Think of it like a map view — grid squares, walls as lines, robot as a colored arrow.
# It reads live state from the map_view instance (level data, object data, player position)
# so it always reflects what's actually happening in the game without needing its own copy.
# Toggle it on/off from the workstation top bar with the "2D View" button.

# Used by: workstation.gd (spawned dynamically into game_subviewport alongside the iso scene)
# Relies on: map_view.gd instance (for level_data, object_data, world_x_size, world_y_size)

extends Node2D

const CELL_SIZE       := 64.0
const WALL_WIDTH      := 7.0

const BG_COLOR        := Color("0b1220")
const FLOOR_COLOR     := Color("233e4c")
const FLOOR_ALT_COLOR := Color("294753")
const GOAL_COLOR      := Color("338c72")
const GOAL_MARKER     := Color(1.0, 1.0, 1.0, 1.0)
const WALL_COLOR      := Color(0x8bffffff)
const GRID_LINE_COLOR := Color("456575")
const PLAYER_COLOR    := Color(0.636, 0.0, 0.822, 1.0)
const PLAYER_RIM      := Color(0.636, 0.0, 0.822, 1.0)
const TRAIL_COLOR     := Color(0.78, 0.25, 0.95, 0.72)
const TRAIL_WIDTH     := 3.0
const TRAIL_OFFSET    := CELL_SIZE * 0.18

const OBJECT_COLORS := {
	"apple":  Color(0.95, 0.28, 0.28),
	"banana": Color(1.00, 0.88, 0.18),
	"carrot": Color(1.00, 0.52, 0.08),
	"star":   Color(0.95, 1.00, 0.55),
	"token":  Color(0.28, 0.82, 1.00),
}

const DEPOSIT_EMPTY_COLOR := Color(0.88, 0.65, 0.15, 0.85)
const DEPOSIT_FULL_COLOR  := Color(0.28, 0.90, 0.45, 1.0)

var _map_ref: Node    = null
var _player_ref: Node = null
var _cols: int        = 0
var _rows: int        = 0
var _camera: Camera2D = null

var _trail: Array[Vector2] = []
var _trail_gx: int    = -1
var _trail_gy: int    = -1
var _trail_facing: String = ""
var show_command_trail := true

# Redraw is expensive (full-grid draw calls), so _process only flags a redraw
# when something actually changed instead of queue_redraw() every frame.
var _dirty := true
var _last_objects_version := -1

# Static draw data, parsed once per level in setup() so _draw never splits
# "x,y" keys or re-scans level_data. Object entries refresh on objects_version.
var _floor_fills: Array = []     # {r: Rect2, c: Color}
var _floor_accents: Array = []   # {a: Vector2, b: Vector2}
var _grid_rects: Array[Rect2] = []
var _wall_rects: Array[Rect2] = []
var _goal_marks: Array = []      # {r: Rect2}
var _deposit_cells: Array = []   # {key, r, c, color, expected}
var _deposit_keys := {}          # "x,y" -> true
var _object_entries: Array = []  # {r: Rect2, c: Color, n: int}

const FLOOR_ACCENT := Color("4a7380")


func _ready() -> void:
	# /root lookup instead of the autoload identifier so this script also
	# works when instantiated outside a normal project run (e.g. tests).
	var settings := get_node_or_null("/root/SettingsManager")
	if settings != null:
		show_command_trail = bool(settings.get_setting("learning", "show_command_trail", true))
	_camera = Camera2D.new()
	_camera.enabled = false
	add_child(_camera)
	get_viewport().size_changed.connect(_fit_camera)


func setup(map_instance: Node, player: Node) -> void:
	_map_ref    = map_instance
	_player_ref = player
	_cols       = map_instance.world_x_size
	_rows       = map_instance.world_y_size
	_trail.clear()
	_trail_gx = -1
	_trail_gy = -1
	_trail_facing = ""
	_dirty = true
	_last_objects_version = -1
	_build_static_caches()
	_rebuild_object_entries()
	if player != null:
		_record_trail(player.grid_x, player.grid_y, player.facing)
	call_deferred("_fit_camera")
	queue_redraw()


## Parses level_data once into flat draw lists so _draw does no string work.
func _build_static_caches() -> void:
	_floor_fills.clear()
	_floor_accents.clear()
	_grid_rects.clear()
	_wall_rects.clear()
	_goal_marks.clear()
	_deposit_cells.clear()
	_deposit_keys.clear()

	for gx in range(1, _cols + 1):
		for gy in range(1, _rows + 1):
			if _map_ref.is_void(gx, gy):
				continue
			var r := _cell_rect(gx, gy)
			_floor_fills.append({
				"r": r,
				"c": FLOOR_COLOR if (gx + gy) % 2 == 0 else FLOOR_ALT_COLOR
			})
			var inset := r.grow(-4.0)
			_floor_accents.append({"a": inset.position, "b": Vector2(inset.end.x, inset.position.y)})
			_grid_rects.append(r)

	if _map_ref.level_data.has("walls"):
		for key in _map_ref.level_data["walls"]:
			var parts := str(key).split(",")
			if parts.size() != 2:
				continue
			var gx := int(parts[0])
			var gy := int(parts[1])
			for d in _map_ref.level_data["walls"][key]:
				_wall_rects.append(_wall_rect_for(gx, gy, str(d).to_lower()))

	if not _map_ref.level_data.has("goal"):
		return
	var goal = _map_ref.level_data["goal"]
	var positions: Array = []
	if goal.has("possible_final_positions"):
		for pos in goal["possible_final_positions"]:
			if typeof(pos) == TYPE_ARRAY and pos.size() >= 2:
				positions.append(Vector2i(int(pos[0]), int(pos[1])))
	if goal.has("position") and typeof(goal["position"]) == TYPE_DICTIONARY:
		var pos = goal["position"]
		positions.append(Vector2i(int(pos.get("x", -1)), int(pos.get("y", -1))))
	for p in positions:
		_goal_marks.append({"r": _cell_rect(p.x, p.y)})

	if not goal.has("objects"):
		return
	for key in goal["objects"]:
		var parts := str(key).split(",")
		if parts.size() != 2:
			continue
		var obj_dict = goal["objects"][key]
		if not (obj_dict is Dictionary) or obj_dict.is_empty():
			continue
		var obj_name: String = ""
		var expected: int = 0
		for k in obj_dict:
			obj_name = str(k)
			expected = int(obj_dict[k])
			break
		var gx := int(parts[0])
		var gy := int(parts[1])
		_deposit_keys[key] = true
		_deposit_cells.append({
			"key": key,
			"r": _cell_rect(gx, gy),
			"c": OBJECT_COLORS.get(obj_name, Color(1, 1, 1)),
			"expected": expected,
			"obj_name": obj_name
		})


## Wall segment rect for one face, matching the old _draw_wall_segment math.
func _wall_rect_for(gx: int, gy: int, dir: String) -> Rect2:
	var r := _cell_rect(gx, gy)
	var hw := WALL_WIDTH / 2.0
	match dir:
		"north":
			return Rect2(r.position.x - hw, r.position.y - hw, CELL_SIZE + WALL_WIDTH, WALL_WIDTH)
		"east":
			return Rect2(r.position.x + CELL_SIZE - hw, r.position.y - hw, WALL_WIDTH, CELL_SIZE + WALL_WIDTH)
		"south":
			return Rect2(r.position.x - hw, r.position.y + CELL_SIZE - hw, CELL_SIZE + WALL_WIDTH, WALL_WIDTH)
		"west":
			return Rect2(r.position.x - hw, r.position.y - hw, WALL_WIDTH, CELL_SIZE + WALL_WIDTH)
	return Rect2()


## Re-parses object_data into draw entries. Only runs when objects_version
## changes (pick/place/restore), never per frame.
func _rebuild_object_entries() -> void:
	_object_entries.clear()
	if _map_ref == null:
		return
	for key in _map_ref.object_data:
		if _deposit_keys.has(key):
			continue
		var parts := str(key).split(",")
		if parts.size() != 2:
			continue
		var tile_objs: Dictionary = _map_ref.object_data[key]
		if tile_objs.is_empty():
			continue
		var color := Color(1, 1, 1)
		var total := 0
		for obj_name in tile_objs:
			color = OBJECT_COLORS.get(str(obj_name), Color(1, 1, 1))
			total += int(tile_objs[obj_name])
		_object_entries.append({"r": _cell_rect(int(parts[0]), int(parts[1])), "c": color, "n": total})


func _right_foot_offset(facing: String) -> Vector2:
	match facing:
		"north": return Vector2( TRAIL_OFFSET,  0)
		"east":  return Vector2( 0,  TRAIL_OFFSET)
		"south": return Vector2(-TRAIL_OFFSET,  0)
		"west":  return Vector2( 0, -TRAIL_OFFSET)
	return Vector2.ZERO


func _record_trail(gx: int, gy: int, facing: String) -> void:
	var center := _cell_rect(gx, gy).get_center()
	var from_off := _right_foot_offset(_trail_facing)
	var to_off   := _right_foot_offset(facing)

	# Turned in place — add a single corner point for a sharp right-angle elbow
	if gx == _trail_gx and gy == _trail_gy and _trail_facing != "" and _trail_facing != facing:
		_trail.append(center + from_off + to_off)

	_trail.append(center + to_off)
	_trail_gx     = gx
	_trail_gy     = gy
	_trail_facing = facing


## Rebuild the trail from a list of {gx, gy, facing} entries (oldest first).
## Used by step-back so the trail shows only the path up to the current state,
## with later segments trimmed off.
func rebuild_trail(positions: Array) -> void:
	_trail.clear()
	_trail_gx = -1
	_trail_gy = -1
	_trail_facing = ""
	_dirty = true
	for p in positions:
		_record_trail(int(p.gx), int(p.gy), String(p.facing))
	queue_redraw()


func activate() -> void:
	_camera.enabled = true
	_camera.make_current()
	call_deferred("_fit_camera")


func deactivate() -> void:
	_camera.enabled = false


func _fit_camera() -> void:
	if _camera == null or _cols == 0 or _rows == 0:
		return
	var grid_w := _cols * CELL_SIZE
	var grid_h := _rows * CELL_SIZE
	_camera.position = Vector2(grid_w / 2.0, grid_h / 2.0)
	var vp_size := get_viewport().get_visible_rect().size
	var zoom: float = minf(vp_size.x / (grid_w + CELL_SIZE * 3.0), vp_size.y / (grid_h + CELL_SIZE * 3.0)) * 0.95
	_camera.zoom = Vector2(zoom, zoom)


func _unhandled_input(event: InputEvent) -> void:
	if not visible or _camera == null:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_camera.zoom = _camera.zoom * 1.12
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_camera.zoom = Vector2(maxf(_camera.zoom.x * 0.89, 0.05), maxf(_camera.zoom.y * 0.89, 0.05))


func _process(_delta: float) -> void:
	# State tracking runs even while hidden so the trail stays correct and a
	# pending redraw is not lost; the redraw itself only happens when visible.
	if _player_ref != null:
		var gx: int        = _player_ref.grid_x
		var gy: int        = _player_ref.grid_y
		var facing: String = _player_ref.facing
		if gx != _trail_gx or gy != _trail_gy or facing != _trail_facing:
			_record_trail(gx, gy, facing)
			_dirty = true
	if _map_ref != null:
		var version = _map_ref.get("objects_version")
		if version != _last_objects_version:
			_last_objects_version = version
			_rebuild_object_entries()
			_dirty = true
	if _dirty and visible:
		_dirty = false
		queue_redraw()


func _draw() -> void:
	if _map_ref == null or _cols == 0 or _rows == 0:
		return
	_draw_background()
	for e in _floor_fills:
		draw_rect(e["r"], e["c"])
	for a in _floor_accents:
		draw_line(a["a"], a["b"], FLOOR_ACCENT, 1.0)
	_draw_goal()
	for r in _grid_rects:
		draw_rect(r, GRID_LINE_COLOR, false, -0.5)
	_draw_walls()
	_draw_border()
	_draw_deposits()
	_draw_objects()
	_draw_trail()
	_draw_player()
	_draw_compass()


# cell (gx, gy) in JSON coords → pixel rect
# JSON: gx=1..cols left→right, gy=1..rows bottom→top
# Screen: y increases downward, so we flip gy
func _cell_rect(gx: int, gy: int) -> Rect2:
	return Rect2(
		Vector2((gx - 1) * CELL_SIZE, (_rows - gy) * CELL_SIZE),
		Vector2(CELL_SIZE, CELL_SIZE)
	)


func _draw_background() -> void:
	# flood the entire canvas so nothing bleeds through around the grid
	draw_rect(Rect2(-10000, -10000, 20000, 20000), BG_COLOR)


func _draw_goal() -> void:
	for e in _goal_marks:
		var r: Rect2 = e["r"]
		draw_rect(r, GOAL_COLOR)
		# small diamond marker in the center
		var c := r.get_center()
		var d := CELL_SIZE * 0.22
		draw_polygon(
			[c + Vector2(0, -d), c + Vector2(d, 0), c + Vector2(0, d), c + Vector2(-d, 0)],
			[GOAL_MARKER, GOAL_MARKER, GOAL_MARKER, GOAL_MARKER]
		)


func _draw_border() -> void:
	var w := _cols * CELL_SIZE
	var h := _rows * CELL_SIZE
	var hw := WALL_WIDTH / 2.0
	draw_rect(Rect2(-hw,      -hw,      w + WALL_WIDTH, WALL_WIDTH), WALL_COLOR)  # top
	draw_rect(Rect2(-hw,      h - hw,   w + WALL_WIDTH, WALL_WIDTH), WALL_COLOR)  # bottom
	draw_rect(Rect2(-hw,      -hw,      WALL_WIDTH, h + WALL_WIDTH), WALL_COLOR)  # left
	draw_rect(Rect2(w - hw,   -hw,      WALL_WIDTH, h + WALL_WIDTH), WALL_COLOR)  # right


func _draw_walls() -> void:
	for r in _wall_rects:
		draw_rect(r, WALL_COLOR)


func _draw_trail() -> void:
	if not show_command_trail:
		return
	if _trail.size() < 2:
		return
	# Start dot
	draw_circle(_trail[0], TRAIL_WIDTH * 1.2, TRAIL_COLOR)
	for i in range(1, _trail.size()):
		draw_line(_trail[i - 1], _trail[i], TRAIL_COLOR, TRAIL_WIDTH, true)


func _draw_player() -> void:
	if _player_ref == null:
		return
	var gx: int        = _player_ref.grid_x
	var gy: int        = _player_ref.grid_y
	var facing: String = _player_ref.facing
	var r      := _cell_rect(gx, gy)
	var center := r.get_center()
	var radius := CELL_SIZE * 0.36

	# outer rim glow
	draw_circle(center, radius + 3.0, PLAYER_RIM)
	# filled circle body
	draw_circle(center, radius, PLAYER_COLOR)

	# directional arrow
	var tip_d  := radius * 0.78
	var base_d := radius * 0.22
	var half_b := radius * 0.42
	var tip: Vector2
	var base_c: Vector2
	match facing:
		"north":
			tip    = center + Vector2(0, -tip_d)
			base_c = center + Vector2(0,  base_d)
		"south":
			tip    = center + Vector2(0,  tip_d)
			base_c = center + Vector2(0, -base_d)
		"east":
			tip    = center + Vector2( tip_d, 0)
			base_c = center + Vector2(-base_d, 0)
		"west":
			tip    = center + Vector2(-tip_d, 0)
			base_c = center + Vector2( base_d, 0)
		_:
			return
	var perp := (tip - base_c).rotated(PI / 2.0).normalized() * half_b
	draw_polygon(
		[tip, base_c + perp, base_c - perp],
		[Color(1, 1, 1, 1.0), Color(1, 1, 1, 1.0), Color(1, 1, 1, 1.0)]
	)


func _draw_compass() -> void:
	var font  := ThemeDB.fallback_font
	var fs    := int(CELL_SIZE * 0.30)
	var col   := Color(0.28, 0.78, 0.92, 0.85)
	var gw    := _cols * CELL_SIZE
	var gh    := _rows * CELL_SIZE
	var pad   := CELL_SIZE * 0.35
	# N above grid center
	draw_string(font, Vector2(gw * 0.5 - fs * 0.3, -pad * 0.3), "N",
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	# S below grid center
	draw_string(font, Vector2(gw * 0.5 - fs * 0.3, gh + pad + fs * 0.5), "S",
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	# E right of grid center
	draw_string(font, Vector2(gw + pad * 0.4, gh * 0.5 + fs * 0.4), "E",
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	# W left of grid center
	draw_string(font, Vector2(-pad - fs * 0.6, gh * 0.5 + fs * 0.4), "W",
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _draw_deposits() -> void:
	if _deposit_cells.is_empty():
		return
	var font       := ThemeDB.fallback_font
	var font_size  := int(CELL_SIZE * 0.22)
	for e in _deposit_cells:
		var actual := 0
		var tile_objs = _map_ref.object_data.get(e["key"], {})
		if tile_objs is Dictionary:
			actual = int(tile_objs.get(e["obj_name"], 0))
		var expected: int = e["expected"]
		var filled  := actual >= expected
		var obj_col: Color = e["c"]
		var c       := (e["r"] as Rect2).get_center()
		var hw      := CELL_SIZE * 0.30
		var box_col := DEPOSIT_FULL_COLOR if filled else DEPOSIT_EMPTY_COLOR
		# square outline
		draw_rect(Rect2(c.x - hw, c.y - hw, hw * 2.0, hw * 2.0), box_col, false, 2.5)
		# small circle: bright object color when empty, dulled when filled
		var circle_col := Color(obj_col, 0.28) if filled else Color(obj_col, 0.85)
		draw_circle(c, CELL_SIZE * 0.22, circle_col)

		# have / needed counts — black on left, cyan on right
		var have_w     := font.get_string_size(str(actual), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var slash_w    := font.get_string_size("/", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var needed_w   := font.get_string_size(str(expected), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var total_w    := have_w + slash_w + needed_w
		var baseline_y := c.y + font_size * 0.38
		var x0         := c.x - total_w * 0.5
		
		draw_string(font, Vector2(x0, baseline_y), str(actual),
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0, 0, 0, 0.95))
		draw_string(font, Vector2(x0 + have_w, baseline_y), "/",
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1, 1, 1, 0.9))
		draw_string(font, Vector2(x0 + have_w + slash_w, baseline_y), str(expected),
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.046, 0.649, 0.924, 1.0))


func _draw_objects() -> void:
	var font      := ThemeDB.fallback_font
	var font_size := int(CELL_SIZE * 0.24)
	for e in _object_entries:
		var r: Rect2 = e["r"]
		var center := r.get_center()
		draw_circle(center, CELL_SIZE * 0.26, e["c"])
		var label_pos := center + Vector2(-font_size * 0.3, font_size * 0.38)
		draw_string(font, label_pos, str(e["n"]), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0, 0, 0, 0.9))
