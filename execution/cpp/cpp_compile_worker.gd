class_name CppCompileWorker
extends RefCounted

const Paths = preload("res://execution/shared/paths.gd")

# Active compile workers. Guarded by _mutex because run() executes on a
# WorkerThreadPool thread while cancel_all() runs on the main thread.
static var _active: Array = []
static var _mutex := Mutex.new()
static var _next_seq := 0
# Latched by cancel_all() so tasks still sitting in the WorkerThreadPool
# queue (not yet inside run(), hence not in _active) also abort on start.
# Never cleared: only call cancel_all() on quit paths, or every later
# compile in the process would auto-cancel.
static var _cancel_all_requested := false

# WorkerThreadPool task callables cannot return values through
# wait_for_task_completion, so the result is published on `result` for the
# main thread to read once the task completes. Kept on a RefCounted (not the
# workstation) so the compile can safely outlive the workstation node; the
# result is then simply discarded.
var result: Dictionary = {}
var _build_dir := ""
var _driver = null
var _cancel_requested := false
var _finished := false
var _seq := -1


# Thin shell: _compile_inner does all the risky work, so _finished and
# _unregister always run even if a runtime error aborts the inner call
# (GDScript errors don't propagate to callers).
func run(source: String, build_dir: String) -> void:
	_build_dir = build_dir
	_register()
	_compile_inner(source, build_dir)
	_finished = true
	_driver = null
	_unregister()


func _compile_inner(source: String, build_dir: String) -> void:
	if _cancel_requested or _cancel_all_requested:
		_set_cancelled()
		return
	var duplicate := _find_duplicate()
	if duplicate != null and _reuse_duplicate(duplicate):
		return
	var background_compiler = preload(Paths.CPP_DRIVER).new()
	_driver = background_compiler
	# A cancel may have landed while finding a duplicate but before the driver
	# existed to receive it; forward it now so the compile aborts immediately.
	if _cancel_requested or _cancel_all_requested:
		_driver.cancel_compile()
	if not background_compiler.prepare_build_files(source, build_dir):
		_set_error(background_compiler.get_prepare_error(), background_compiler.get_prepare_reason())
	else:
		result = background_compiler.compile_program()


# Asks this worker's compile to stop. Safe to call from any thread and before
# run() has started (the task then exits immediately).
func cancel() -> void:
	_cancel_requested = true
	if _driver != null and _driver.has_method("cancel_compile"):
		_driver.cancel_compile()


# Cancels every in-flight compile, including ones abandoned by dead
# workstations. Call before quitting so shutdown doesn't wait on cc1plus.
static func cancel_all() -> void:
	_cancel_all_requested = true
	_mutex.lock()
	var workers := _active.duplicate()
	_mutex.unlock()
	for worker in workers:
		if is_instance_valid(worker):
			worker.cancel()


func _register() -> void:
	_mutex.lock()
	if not _active.has(self):
		_seq = _next_seq
		_next_seq += 1
		_active.append(self)
	_mutex.unlock()


func _unregister() -> void:
	_mutex.lock()
	_active.erase(self)
	_mutex.unlock()


# Another worker compiling into the same build dir would race on the same
# source/object/exe files, so identical compiles share one result.
func _find_duplicate() -> CppCompileWorker:
	_mutex.lock()
	var duplicate: CppCompileWorker = null
	for worker in _active:
		# Only dedupe onto an earlier registrant so two workers can't pick
		# each other and wait forever.
		if worker != self and is_instance_valid(worker) \
				and worker._build_dir == _build_dir and not worker._finished \
				and worker._seq >= 0 and worker._seq < _seq:
			duplicate = worker
			break
	_mutex.unlock()
	return duplicate


# Returns false when the duplicate's result shouldn't be adopted (a cancelled
# compile is transient, not a property of the source), so the caller compiles
# fresh instead of reporting a spurious failure.
func _reuse_duplicate(duplicate: CppCompileWorker) -> bool:
	while not duplicate._finished and not _cancel_requested and not _cancel_all_requested:
		OS.delay_msec(100)
	if _cancel_requested or _cancel_all_requested:
		_set_cancelled()
		return true
	# The wait loop only exits on _finished or a cancel flag, so the duplicate
	# is guaranteed finished here. Reject transient/empty results so the
	# caller compiles fresh instead of reporting a spurious failure.
	if duplicate.result.is_empty() \
			or str(duplicate.result.get("reason", "")) == "cancelled":
		return false
	result = duplicate.result.duplicate()
	return true


func _set_error(output: String, reason: String) -> void:
	result = {"ok": false, "output": output, "reason": reason, "exe_path": ""}


func _set_cancelled() -> void:
	_set_error("Compilation cancelled.", "cancelled")
