extends RefCounted

const BUILD_DIR := "user://build"
const RUNTIME_CACHE_DIR := "user://build/runtime_cache"
const STUDENT_CPP := "user://build/student_code.cpp"
const ROBOT_HPP := "user://build/robot.hpp"
const ROBOT_CPP := "user://build/robot_runtime.cpp"
const OUTPUT_EXE := "user://build/student_program"
const Paths = preload("res://execution/shared/paths.gd")

var _commands = preload(Paths.ROBOT_COMMANDS).new()
var _active_build_dir: String = ""
var _runtime_object_path := ""
# -1 = not probed yet, 0 = unavailable, 1 = available. Probing spawns g++ --version,
# so the result is cached for the session instead of on every check/run.
var _available_cache := -1
var _compiler_version := ""

func _get_exe_path() -> String:
	var base := _active_build_dir.path_join("student_program")

	if OS.get_name() == "Windows":
		return base + ".exe"

	return base


func prepare_build_files(source: String, port: int, token: String, sandbox_path: String = "", pipe_name: String = "") -> void:

	# Populate _compiler_version before the runtime fingerprint is computed.
	is_available()

	var build_dir := sandbox_path if not sandbox_path.is_empty() else ProjectSettings.globalize_path(BUILD_DIR)
	_active_build_dir = build_dir
	DirAccess.make_dir_recursive_absolute(build_dir)
	_write_file(build_dir.path_join("student_code.cpp"), source)
	var header_source := _commands.get_cpp_header()
	_write_file(build_dir.path_join("robot.hpp"), header_source)
	var runtime_source := _commands.get_cpp_pipe_source()
	_write_file(build_dir.path_join("robot_runtime.cpp"), runtime_source)

	# The generated runtime/header rarely change between checks, so its object file
	# is cached under user://build and shared across build dirs. The fingerprint
	# covers everything that affects the object: sources, compiler, and platform.
	var fingerprint := "%s\n%s\n%s\n%s" % [
		header_source, runtime_source, _compiler_version, OS.get_name()
	]
	_runtime_object_path = ProjectSettings.globalize_path(RUNTIME_CACHE_DIR).path_join(
		"robot_runtime_%s.o" % fingerprint.md5_text()
	)

func is_available() -> bool:
	if _available_cache == -1:
		var output: Array = []
		_available_cache = 1 if OS.execute("g++", ["--version"], output, true) == 0 else 0
		if _available_cache == 1 and not output.is_empty():
			_compiler_version = str(output[0]).split("\n")[0]
	return _available_cache == 1

func compile_program() -> Dictionary:
	var output: Array = []
	if _active_build_dir.is_empty():
		return {
			"ok": false,
			"output": "No build directory was prepared."
		}

	# Populate _compiler_version on whichever instance runs the compile
	# (the check path uses a fresh driver inside a worker thread).
	is_available()

	var student_cpp := _active_build_dir.path_join("student_code.cpp")
	var robot_cpp := _active_build_dir.path_join("robot_runtime.cpp")
	var exe         := _get_exe_path()

	if FileAccess.file_exists(exe):
		DirAccess.remove_absolute(exe)

	var args := ["-std=c++17", "-Wall", "-Wextra", "-s"]

	if OS.get_name() == "Windows":
		args.append("-static")

	# Reuse the cached robot_runtime object when present; otherwise compile it
	# once into the shared cache, then link. Compile to a temp name and rename
	# so an interrupted compile can't leave a corrupt object behind.
	var runtime_input := _runtime_object_path
	if not FileAccess.file_exists(runtime_input):
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(RUNTIME_CACHE_DIR)
		)
		var object_tmp := _runtime_object_path + ".tmp"
		var object_args := ["-std=c++17", "-Wall", "-Wextra", "-c", robot_cpp, "-o", object_tmp]
		var object_code := OS.execute("g++", object_args, output, true)
		if object_code != 0:
			DirAccess.remove_absolute(object_tmp)
			return {
				"ok":     false,
				"output": "" if output.is_empty() else str(output[0])
			}
		DirAccess.rename_absolute(object_tmp, _runtime_object_path)
		runtime_input = _runtime_object_path

	args.append_array([student_cpp, runtime_input, "-o", exe])

	if OS.get_name() == "Windows":
		args.append("-lws2_32")
	var exit_code := OS.execute("g++", args, output, true)
	return {
		"ok":     exit_code == 0,
		"output": "" if output.is_empty() else str(output[0])
	}


func start_program() -> int:
	return OS.create_process(_get_exe_path(), [])

func remap_diagnostics(raw_text: String, line_offset: int) -> String:
	var result: Array[String] = []

	for line in raw_text.split("\n"):
		if line.strip_edges() == "":
			continue

		# Skip compiler context lines not useful to the student
		if "In function" in line or "In member" in line or "note:" in line:
			continue

		# Skip g++ code context lines: "6 | move()" / "| ^" / "| ~" / "| ;"
		var trimmed := line.strip_edges()
		if trimmed.begins_with("| ") or trimmed == "|":
			continue
		if trimmed.length() > 2 and trimmed[0].is_valid_int() and " | " in trimmed:
			continue
		
		if "undefined reference" in trimmed or "multiple definition" in trimmed or "Permission denied" in trimmed:
			result.append(trimmed)
			continue
		
		var parts := line.split(":")
		# Determine path offset for Windows drive letters
		var offset := 0
		if parts.size() > 1 and parts[0].length() == 1 and parts[0][0].to_upper() == parts[0][0]:
			offset = 1

		if parts.size() >= (4 + offset) and parts[1 + offset].strip_edges().is_valid_int():
			var line_num := int(parts[1 + offset].strip_edges())
			var severity_and_msg := ":".join(parts.slice(3 + offset)).strip_edges()
			var student_line : int = max(1, line_num - line_offset)
			result.append("%s (line %d)" % [severity_and_msg, student_line])
		else:
			if trimmed.begins_with("/") or (trimmed.length() > 1 and trimmed[1] == ":"):
				continue
			result.append(line)
			
	return "\n".join(result)

func _write_file(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("Failed to open file for writing: " + path)
		return
	f.store_string(text)
