extends RefCounted

# level_validator.gd

const VALID_DIRECTIONS := ["north", "south", "east", "west"]


static func validate_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _fail("File not found: %s" % path)

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _fail("Could not open file: %s" % path)
	var text := file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(text) != OK:
		return _fail("Invalid JSON (line %d): %s" % [json.get_error_line(), json.get_error_message()])

	return validate_data(json.data)


static func validate_data(data: Variant) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY:
		return _fail("Level JSON must be an object at the top level.")

	# --- rows / cols ---
	for key in ["rows", "cols"]:
		if not data.has(key):
			return _fail("Missing required field \"%s\"." % key)
		if not _is_whole_number(data[key]) or int(data[key]) < 1:
			return _fail("\"%s\" must be a whole number of at least 1." % key)
	var cols := int(data["cols"])
	var rows := int(data["rows"])

	# --- robots ---
	if not data.has("robots"):
		return _fail("Missing required field \"robots\".")
	if typeof(data["robots"]) != TYPE_ARRAY or (data["robots"] as Array).is_empty():
		return _fail("\"robots\" must be a non-empty list.")
	var robot = data["robots"][0]
	if typeof(robot) != TYPE_DICTIONARY:
		return _fail("The first entry in \"robots\" must be an object.")
	for key in ["x", "y"]:
		if not robot.has(key) or not _is_whole_number(robot[key]):
			return _fail("Robot is missing a whole-number \"%s\" position." % key)
	if not _in_grid(int(robot["x"]), int(robot["y"]), cols, rows):
		return _fail("Robot start (%d,%d) is outside the %dx%d grid." % [int(robot["x"]), int(robot["y"]), cols, rows])

	# --- walls (optional) ---
	if data.has("walls"):
		if typeof(data["walls"]) != TYPE_DICTIONARY:
			return _fail("\"walls\" must be an object.")
		for wall_key in data["walls"]:
			if not _is_cell_key(str(wall_key)):
				return _fail("Bad wall coordinate \"%s\" (expected \"x,y\")." % wall_key)
			var dirs = data["walls"][wall_key]
			if typeof(dirs) != TYPE_ARRAY or (dirs as Array).is_empty():
				return _fail("Wall at \"%s\" must be a non-empty list of directions." % wall_key)
			for d in dirs:
				if typeof(d) != TYPE_STRING or not VALID_DIRECTIONS.has((d as String).to_lower()):
					return _fail("Wall at \"%s\" has an invalid direction: %s" % [wall_key, str(d)])

	# --- objects (optional) ---
	if data.has("objects"):
		var err := _check_object_map(data["objects"], "objects")
		if err != "":
			return _fail(err)

	# --- goal (optional) ---
	if data.has("goal"):
		var goal = data["goal"]
		if typeof(goal) != TYPE_DICTIONARY:
			return _fail("\"goal\" must be an object.")

		if goal.has("possible_final_positions"):
			var positions = goal["possible_final_positions"]
			if typeof(positions) != TYPE_ARRAY:
				return _fail("\"goal.possible_final_positions\" must be a list.")
			for pos in positions:
				if typeof(pos) != TYPE_ARRAY or pos.size() < 2 \
						or not _is_whole_number(pos[0]) or not _is_whole_number(pos[1]):
					return _fail("Each goal final position must look like [x, y].")

		if goal.has("position"):
			var gpos = goal["position"]
			if typeof(gpos) != TYPE_DICTIONARY \
					or not gpos.has("x") or not _is_whole_number(gpos["x"]) \
					or not gpos.has("y") or not _is_whole_number(gpos["y"]):
				return _fail("\"goal.position\" must be an object with whole-number x and y.")

		if goal.has("objects"):
			var goal_err := _check_object_map(goal["objects"], "goal.objects")
			if goal_err != "":
				return _fail(goal_err)

	return { "ok": true, "error": "" }


# ---- helpers ----

# "objects" and "goal.objects" share a shape: { "x,y": { "apple": 2, ... } }
static func _check_object_map(value: Variant, label: String) -> String:
	if typeof(value) != TYPE_DICTIONARY:
		return "\"%s\" must be an object." % label
	for cell_key in value:
		if not _is_cell_key(str(cell_key)):
			return "Bad coordinate \"%s\" in \"%s\" (expected \"x,y\")." % [cell_key, label]
		var items = value[cell_key]
		if typeof(items) != TYPE_DICTIONARY:
			return "Entry \"%s\" in \"%s\" must be an object of name: count." % [cell_key, label]
		for item_name in items:
			if not _is_whole_number(items[item_name]) or int(items[item_name]) < 0:
				return "Count for \"%s\" at \"%s\" in \"%s\" must be a whole number." % [item_name, cell_key, label]
	return ""


static func _is_whole_number(v: Variant) -> bool:
	if typeof(v) == TYPE_INT:
		return true
	return typeof(v) == TYPE_FLOAT and v == floorf(v)


static func _is_cell_key(s: String) -> bool:
	var parts := s.split(",")
	return parts.size() == 2 and parts[0].strip_edges().is_valid_int() and parts[1].strip_edges().is_valid_int()


static func _in_grid(x: int, y: int, cols: int, rows: int) -> bool:
	return x >= 1 and x <= cols and y >= 1 and y <= rows


static func _fail(message: String) -> Dictionary:
	return { "ok": false, "error": message }
