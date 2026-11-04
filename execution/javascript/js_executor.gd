extends RefCounted

# JavaScript executor using Node.js
# Executes Reeborg's World JavaScript API scripts (onload/pre/post)

var _output := ""
var _error := ""
var _modified_level_data: Dictionary = {}
var _public_data: Dictionary = {}

# Supported object types for validation
const SUPPORTED_OBJECTS = ["apple", "banana", "carrot", "star", "token"]


# Execute a JavaScript script and return the result
# script_array: Array of JavaScript code lines (from JSON)
# level_data: The current level dictionary (will be modified by scripts)
# movement_history: Array of [x, y] positions for path validation (optional)
# Returns: Dictionary with {ok: bool, modified_data: Dictionary, public_data: Dictionary, error: String}
func execute_script(script_array: Array, level_data: Dictionary, movement_history: Array = []) -> Dictionary:
	_output = ""
	_error = ""
	_modified_level_data = level_data.duplicate(true)
	_public_data = {}

	if script_array.is_empty():
		return {
			"ok": true,
			"modified_data": _modified_level_data,
			"public_data": _public_data,
			"error": ""
		}

	# Combine script lines into a single string
	var script_code := "\n".join(script_array)

	# Wrap the script in a function that can call our RUR API
	var wrapped_script = _build_wrapped_script(script_code)

	# Check if Node.js is available
	var node_check := _check_nodejs()
	if not node_check.ok:
		return {
			"ok": false,
			"modified_data": level_data,
			"public_data": {},
			"error": "Node.js not found: " + node_check.error
		}

	# Write temporary script file
	var temp_dir := OS.get_user_data_dir()
	var script_path := temp_dir.path_join("reeborg_script.js")
	var script_file := FileAccess.open(script_path, FileAccess.WRITE)
	if script_file == null:
		return {
			"ok": false,
			"modified_data": level_data,
			"public_data": {},
			"error": "Failed to create temp script file"
		}

	script_file.store_string(wrapped_script)
	script_file.close()

	# Execute with Node.js
	var node_path := _find_nodejs_executable()
	var output_path := temp_dir.path_join("reeborg_output.json")

	var exit_code := OS.execute(
		node_path,
		[script_path, JSON.stringify(_modified_level_data), output_path, JSON.stringify(movement_history)],
		[],
		true
	)

	# Read the output
	var output_file := FileAccess.open(output_path, FileAccess.READ)
	if output_file == null:
		# Clean up temp files
		DirAccess.remove_absolute(script_path)
		return {
			"ok": false,
			"modified_data": level_data,
			"public_data": {},
			"error": "Failed to read script output"
		}

	var output_text := output_file.get_as_text()
	output_file.close()

	# Clean up temp files
	DirAccess.remove_absolute(script_path)
	DirAccess.remove_absolute(output_path)

	# Parse the output
	var json := JSON.new()
	var parse_result := json.parse(output_text)

	if parse_result != OK:
		return {
			"ok": false,
			"modified_data": level_data,
			"public_data": {},
			"error": "Failed to parse script output: " + json.get_error_message()
		}

	var result = json.data

	if result.has("error") and result["error"] != "":
		return {
			"ok": false,
			"modified_data": level_data,
			"public_data": {},
			"error": result["error"]
		}

	_modified_level_data = result.get("modified_data", _modified_level_data)
	_public_data = result.get("public_data", {})

	return {
		"ok": true,
		"modified_data": _modified_level_data,
		"public_data": _public_data,
		"error": ""
	}


# Build the wrapped script that includes the RUR API
func _build_wrapped_script(user_script: String) -> String:
	var api_script = _get_rur_api_implementation()
	return api_script + "\n\n// === User Script ===\n" + user_script


# Get the RUR API implementation as JavaScript code
func _get_rur_api_implementation() -> String:
	return """
// === RUR API Implementation for Code & Conqueror ===

const fs = require('fs');

// Read input arguments
const levelData = JSON.parse(process.argv[2]);
const outputPath = process.argv[3];
const movementHistory = process.argv[4] ? JSON.parse(process.argv[4]) : [];

// RUR public object for storing custom data
const RUR = {
	public: {},
	state: {
		visible_grid: true
	}
};

// Random number generator
RUR.randint = function(min, max) {
	return Math.floor(Math.random() * (max - min + 1)) + min;
};

// Set world size
RUR.set_world_size = function(width, height) {
	levelData.cols = width;
	levelData.rows = height;
};

// Give object to robot
RUR.give_object_to_robot = function(objectType, count) {
	if (!levelData.robots || levelData.robots.length === 0) {
		levelData.robots = [{x: 1, y: 1, _orientation: 0, objects: {}}];
	}
	if (!levelData.robots[0].objects) {
		levelData.robots[0].objects = {};
	}
	if (!levelData.robots[0].objects[objectType]) {
		levelData.robots[0].objects[objectType] = 0;
	}
	levelData.robots[0].objects[objectType] += count;
};

// Add object to level
RUR.add_object = function(objectType, x, y, options) {
	const key = x + ',' + y;
	if (!levelData.objects) {
		levelData.objects = {};
	}
	if (!levelData.objects[key]) {
		levelData.objects[key] = {};
	}
	if (!levelData.objects[key][objectType]) {
		levelData.objects[key][objectType] = 0;
	}
	const count = (options && options.number) ? options.number : 1;
	levelData.objects[key][objectType] += count;
};

// Add background tile (STUB - stores data but no visual effect)
RUR.add_background_tile = function(tileType, x, y) {
	const key = x + ',' + y;
	if (!levelData.tiles) {
		levelData.tiles = {};
	}
	if (!levelData.tiles[key]) {
		levelData.tiles[key] = [];
	}
	if (!levelData.tiles[key].includes(tileType)) {
		levelData.tiles[key].push(tileType);
	}
};

// Fill background with tile type (STUB - stores data but no visual effect)
RUR.fill_background = function(tileType) {
	// Store as default, but Code & Conqueror doesn't use this yet
	levelData._default_tile = tileType;
};

// Show path (STUB - stores data but no visual effect)
RUR.show_path = function(path, color) {
	RUR.public._path = path;
	RUR.public._path_color = color;
};

// Check path (validates movement history)
RUR.check_path = function(requiredPath, options) {
	// Validate that movement history matches required path
	// Required path format: [[x1, y1], [x2, y2], ...]
	// Movement history format: [[x1, y1], [x2, y2], ...]

	// Check if path lengths match
	if (movementHistory.length !== requiredPath.length) {
		const result = {
			success: false,
			failure: (options && options.failure) ? options.failure : "Path length mismatch",
			show_path: (options && options.show_path) ? options.show_path : false,
			color: (options && options.color) ? options.color : "black"
		};
		return result;
	}

	// Check each position
	for (let i = 0; i < requiredPath.length; i++) {
		const required = requiredPath[i];
		const actual = movementHistory[i];
		if (required[0] !== actual[0] || required[1] !== actual[1]) {
			const result = {
				success: false,
				failure: (options && options.failure) ? options.failure : "Path mismatch at position " + (i + 1),
				show_path: (options && options.show_path) ? options.show_path : false,
				color: (options && options.color) ? options.color : "black"
			};
			return result;
		}
	}

	// Path matches
	const result = {
		success: true,
		failure: (options && options.failure) ? options.failure : "",
		show_path: (options && options.show_path) ? options.show_path : false,
		color: (options && options.color) ? options.color : "black"
	};
	return result;
};

// MAX_STEPS (execution limit)
let MAX_STEPS = 1000;

// Allow scripts to set MAX_STEPS
Object.defineProperty(RUR, 'MAX_STEPS', {
	get: function() { return MAX_STEPS; },
	set: function(value) {
		MAX_STEPS = value;
		levelData._MAX_STEPS = value;  // Store for Code & Conquer to read
	}
});

// UsedRobot class (simplified - just stores position)
class UsedRobot {
	constructor(x, y) {
		this.x = x;
		this.y = y;
	}
}

// === Execute and Write Output ===
try {
	// If there's an error, catch it and report it
} catch (e) {
	fs.writeFileSync(outputPath, JSON.stringify({
		error: e.toString(),
		modified_data: levelData,
		public_data: RUR.public
	}));
	process.exit(1);
}

// Write successful output
fs.writeFileSync(outputPath, JSON.stringify({
	error: "",
	modified_data: levelData,
	public_data: RUR.public
}));
"""


# Check if Node.js is available
func _check_nodejs() -> Dictionary:
	var node_path := _find_nodejs_executable()
	if node_path == "":
		return {
			"ok": false,
			"error": "Node.js executable not found in PATH"
		}

	# Test if it works
	var exit_code := OS.execute(node_path, ["--version"], [], true)
	if exit_code != 0:
		return {
			"ok": false,
			"error": "Node.js executable failed to run"
		}

	return {"ok": true, "error": ""}


# Find Node.js executable on the system
func _find_nodejs_executable() -> String:
	var possible_names = ["node", "nodejs"]

	for name in possible_names:
		# Try to execute the command to see if it exists
		var exit_code := OS.execute(name, ["--version"], [], true)
		if exit_code == 0:
			return name

	return ""
