extends RefCounted

const BUILD_DIR := "user://build"
const Paths = preload("res://execution/shared/paths.gd")

var _commands = preload(Paths.ROBOT_COMMANDS).new()
var _runtime_assets = preload(Paths.RUNTIME_ASSETS).new()
var _active_build_dir: String = ""
var _prepare_error: String = ""
var _prepare_reason: String = ""
var _cancel_requested := false
var _compiler_pid := -1
static var _compiler: String = ""
static var _compiler_probed := false
static var _compiler_version_output: Array = []


func _get_exe_path() -> String:
	var base := _active_build_dir.path_join("student_program")
	return base + ".exe" if OS.get_name() == "Windows" else base


func prepare_build_files(source: String, sandbox_path: String = "", ipc_endpoint: String = "") -> bool:
	_prepare_error = ""
	_prepare_reason = ""
	_active_build_dir = ""
	var tag := _runtime_assets.platform_tag()
	if tag.is_empty():
		_prepare_error = "C++ execution is not supported on this OS or architecture."
		_prepare_reason = "unsupported_platform"
		return false

	var runtime_source := ""
	match OS.get_name():
		"Windows":
			runtime_source = _commands.get_cpp_pipe_source()
		"Linux", "macOS":
			runtime_source = _commands.get_cpp_unix_source()
		_:
			_prepare_error = "C++ execution is not supported on this OS."
			_prepare_reason = "unsupported_platform"
			return false

	var build_dir := sandbox_path if not sandbox_path.is_empty() else ProjectSettings.globalize_path(BUILD_DIR)
	_active_build_dir = build_dir
	DirAccess.make_dir_recursive_absolute(build_dir)
	var files := {
		"student_code.cpp": source,
		"robot.hpp": _commands.get_cpp_header(),
		"robot_runtime.cpp": runtime_source,
	}
	for name in files:
		if not _write_file(build_dir.path_join(name), files[name]):
			_prepare_error = "Failed to write C++ build files."
			_prepare_reason = "prepare_error"
			return false
	return true


func get_prepare_error() -> String:
	return _prepare_error


func get_prepare_reason() -> String:
	return _prepare_reason


func is_platform_supported() -> bool:
	return not _runtime_assets.platform_tag().is_empty()


func detect_compiler() -> bool:
	return _find_compiler() != ""


func is_available() -> bool:
	return is_platform_supported() and detect_compiler()


# Asks the in-flight compiler (if any) to stop. Kills the whole process tree
# because g++ spawns children (cc1plus, collect2, ld) that would otherwise be
# orphaned and keep burning resources after the parent dies.
func cancel_compile() -> void:
	_cancel_requested = true
	if _compiler_pid > 0 and OS.is_process_running(_compiler_pid):
		_kill_process_tree(_compiler_pid)


func _cancelled_result() -> Dictionary:
	return {"ok": false, "output": "Compilation cancelled.", "reason": "cancelled", "exe_path": ""}


# Runs the compiler without blocking forever: polls the child PID so cancel()
# can kill it, drains both output pipes so a chatty compiler can't deadlock on
# a full pipe buffer, and returns the exit code (-1 on spawn failure/cancel).
func _run_cancellable(compiler: String, args: Array, output: Array) -> int:
	if _cancel_requested:
		return -1
	var pipes := OS.execute_with_pipe(compiler, PackedStringArray(args), false)
	if pipes.is_empty() or not pipes.has("pid"):
		push_warning("Failed to spawn compiler: " + compiler)
		return -2  # spawn failure, distinct from a real compile failure
	_compiler_pid = int(pipes["pid"])
	var stdio: FileAccess = pipes.get("stdio")
	var stderr: FileAccess = pipes.get("stderr")

	while _compiler_pid > 0 and OS.is_process_running(_compiler_pid):
		if _cancel_requested:
			_kill_process_tree(_compiler_pid)
			break
		_drain_pipe(stdio, output)
		_drain_pipe(stderr, output)
		OS.delay_msec(50)

	# Give a killed tree a moment to actually die, then reap the exit code.
	var waited := 0
	while _compiler_pid > 0 and OS.is_process_running(_compiler_pid) and waited < 2000:
		OS.delay_msec(50)
		waited += 50
	if _compiler_pid > 0 and OS.is_process_running(_compiler_pid):
		push_warning("Compiler process %d did not exit after kill" % _compiler_pid)

	# Final drain runs once the process is gone; retry empty reads briefly so
	# diagnostics after a blank line aren't dropped (pipe eof is unreliable).
	_drain_pipe(stdio, output, true)
	_drain_pipe(stderr, output, true)
	if stdio != null:
		stdio.close()
	if stderr != null:
		stderr.close()

	var exit_code := -1
	if _compiler_pid > 0:
		# Always read the exit status, even for a cancelled/killed compile, so
		# the child doesn't linger as an unreaped zombie. Cancelled compiles
		# still report -1 to the caller.
		var reaped := OS.get_process_exit_code(_compiler_pid)
		if not _cancel_requested:
			exit_code = reaped
	_compiler_pid = -1
	return exit_code


# `final` mode is used for the post-exit drain: an empty get_line() may mean
# "no data yet" rather than a blank line, so retry a few times before giving
# up. Mid-run polls break on the first empty read since the next tick retries.
# Known trade-off: get_line() returns whatever bytes are available, so a very
# long line without a newline can stall pipe polling until more data or a
# newline arrives; cancel() killing the process from another thread is the
# escape hatch.
func _drain_pipe(file: FileAccess, output: Array, final: bool = false) -> void:
	if file == null:
		return
	var empty_reads := 0
	while not file.eof_reached():
		var line := file.get_line()
		if line == "":
			if not final:
				break
			empty_reads += 1
			if empty_reads > 5:
				break
			OS.delay_msec(20)
			continue
		empty_reads = 0
		output.append(line)


func _kill_process_tree(pid: int) -> void:
	if pid <= 0:
		return
	if OS.get_name() == "Windows":
		OS.execute("taskkill", ["/F", "/T", "/PID", str(pid)], [], true)
		return
	for child in _child_pids(pid):
		_kill_process_tree(child)
	if OS.is_process_running(pid):
		OS.kill(pid)


func _child_pids(pid: int) -> Array[int]:
	var children: Array[int] = []
	var out: Array = []
	# pgrep is procps-only; fall back to ps (POSIX) on minimal systems so
	# compiler children don't get orphaned when pgrep is missing.
	if OS.execute("pgrep", ["-P", str(pid)], out, true) != OK or out.is_empty():
		out.clear()
		if OS.execute("ps", ["-eo", "pid=,ppid="], out, true) != OK:
			return children
		for entry in out:
			var fields := str(entry).split(" ", false)
			if fields.size() >= 2 and fields[1].to_int() == pid and fields[0].is_valid_int():
				children.append(int(fields[0]))
		return children
	for entry in out:
		var text := str(entry).strip_edges()
		if text.is_valid_int():
			children.append(int(text))
	return children


func compile_program() -> Dictionary:
	var output: Array = []
	if not _prepare_error.is_empty():
		return {
			"ok": false,
			"output": _prepare_error,
			"reason": _prepare_reason if not _prepare_reason.is_empty() else "prepare_error",
			"exe_path": ""
		}
	if _active_build_dir.is_empty():
		return {
			"ok": false,
			"output": "No build directory was prepared.",
			"reason": "internal_error",
			"exe_path": ""
		}

	var compiler := _find_compiler()
	if compiler.is_empty():
		return {
			"ok": false,
			"output": "A C++ compiler was not found.",
			"reason": "no_compiler",
			"exe_path": ""
		}

	var student_cpp := _active_build_dir.path_join("student_code.cpp")
	var robot_cpp := _active_build_dir.path_join("robot_runtime.cpp")
	var exe := _get_exe_path()

	var args := ["-std=c++17", "-Wall", "-Wextra"]
	if OS.get_name() == "Windows":
		args.append("-static")
	var runtime_key := (_runtime_assets.platform_tag() + compiler + str(_compiler_version_output) + str(args) + FileAccess.get_file_as_string(robot_cpp)
		+ FileAccess.get_file_as_string(_active_build_dir.path_join("robot.hpp"))).sha256_text()
	var build_key := (runtime_key + FileAccess.get_file_as_string(student_cpp)).sha256_text()
	var cache_path := _active_build_dir.path_join("compile_cache.cfg")
	var cache := ConfigFile.new()
	cache.load(cache_path)
	var exe_hash := FileAccess.get_sha256(exe)
	if _cancel_requested:
		return _cancelled_result()
	if cache.get_value("build", "key", "") == build_key and exe_hash != "" \
			and cache.get_value("build", "exe_hash", "") == exe_hash:
		return {"ok": true, "output": "", "exe_path": exe, "cached": true}

	# Student edits reuse the compiled robot runtime.
	var runtime_object := _active_build_dir.path_join("robot_runtime.o")
	var runtime_reused := false
	if cache.get_value("runtime", "key", "") == runtime_key and FileAccess.file_exists(runtime_object):
		runtime_reused = cache.get_value("runtime", "object_hash", "") == FileAccess.get_sha256(runtime_object)
	if not runtime_reused:
		var runtime_args := args.duplicate()
		runtime_args.append_array(["-c", robot_cpp, "-o", runtime_object])
		var runtime_code := _run_cancellable(compiler, runtime_args, output)
		if _cancel_requested:
			return _cancelled_result()
		if runtime_code == -2:
			return {"ok": false, "output": "Failed to launch the C++ compiler.", "reason": "internal_error", "exe_path": ""}
		if runtime_code != 0:
			return {"ok": false, "output": "\n".join(output), "reason": "runtime_error", "exe_path": ""}
		var runtime_object_hash := FileAccess.get_sha256(runtime_object)
		if runtime_object_hash.is_empty():
			return {
				"ok": false,
				"output": "Compiled robot runtime could not be hashed.",
				"reason": "internal_error",
				"exe_path": ""
			}
		cache.set_value("runtime", "key", runtime_key)
		cache.set_value("runtime", "object_hash", runtime_object_hash)
		cache.save(cache_path)

	# Failed builds must not reuse an older successful executable.
	if cache.has_section("build"):
		cache.erase_section("build")
	cache.save(cache_path)
	if FileAccess.file_exists(exe):
		DirAccess.remove_absolute(exe)
	args.append_array([student_cpp, runtime_object, "-o", exe])
	if OS.get_name() == "Windows":
		args.append("-lws2_32")

	# Discard runtime compile output so its warnings aren't misattributed to student code.
	output.clear()

	var exit_code := _run_cancellable(compiler, args, output)
	if _cancel_requested:
		return _cancelled_result()
	var diagnostics := "\n".join(output)
	if exit_code == 0:
		cache.set_value("build", "key", build_key)
		cache.set_value("build", "exe_hash", FileAccess.get_sha256(exe))
	cache.save(cache_path)
	return {
		"ok": exit_code == 0,
		"output": diagnostics if exit_code != -2 else "Failed to launch the C++ compiler.",
		"reason": "" if exit_code == 0 else ("internal_error" if exit_code == -2 else "compile_error"),
		"cached": false,
		"exe_path": exe if exit_code == 0 else ""
	}


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


func _find_compiler() -> String:
	if not _compiler.is_empty():
		return _compiler
	if _compiler_probed:
		return ""
	_compiler_probed = true
	for candidate in ["g++", "clang++", "c++"]:
		var output: Array = []
		if OS.execute(candidate, ["--version"], output, true) == 0:
			_compiler_version_output = output
			_compiler = candidate
			return _compiler
	return ""


func _write_file(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("Failed to open file for writing: " + path)
		return false
	if not f.store_string(text):
		f.close()
		push_error("Failed to write file: " + path)
		return false
	f.close()
	return true
