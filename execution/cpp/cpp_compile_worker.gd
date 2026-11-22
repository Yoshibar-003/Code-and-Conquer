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


# Thin shell: _compile_inner does all the risky work and returns the result
# dict, so _finished/_unregister always run even if a runtime error aborts
# the inner call (GDScript errors don't propagate to callers). result and
# _finished are published together under _mutex so a dedupe waiter can't
# observe completion before the result is visible.
func run(source: String, build_dir: String) -> void:
	_build_dir = build_dir
	_register()
	var res = _compile_inner(source, build_dir)
	_mutex.lock()
	result = res if res is Dictionary else {}
	_finished = true
	_mutex.unlock()
	_driver = null
	_unregister()


func _compile_inner(source: String, build_dir: String) -> Variant:
	# Loop because a rejected duplicate (cancelled/empty result) sends this
	# worker back to _find_duplicate, where it can adopt another waiter that
	# is now the earliest registrant; serializing rebuilds of the same dir.
	while true:
		if _cancel_requested or _cancel_all_requested:
			return _cancelled_result()
		var duplicate := _find_duplicate()
		if duplicate == null:
			break
		var reused: Dictionary = _reuse_duplicate(duplicate)
		if not reused.is_empty():
			return reused
	var background_compiler = preload(Paths.CPP_DRIVER).new()
	_driver = background_compiler
	# A cancel may have landed while finding a duplicate but before the driver
	# existed to receive it; forward it now so the compile aborts immediately.
	if _cancel_requested or _cancel_all_requested:
		_driver.cancel_compile()
	if not background_compiler.prepare_build_files(source, build_dir):
		return _error_result(background_compiler.get_prepare_error(), background_compiler.get_prepare_reason())
	return background_compiler.compile_program()


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


# Clears the quit-only latch. Only needed if a future WM_CLOSE_REQUEST handler
# aborts the close after cancel_all() already ran.
static func reset_cancel_all() -> void:
	_cancel_all_requested = false


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


# Returns the duplicate's result to adopt, or {} when it shouldn't be
# adopted (a cancelled/empty result is transient, not a property of the
# source) so the caller compiles fresh instead of reporting a spurious
# failure.
func _reuse_duplicate(duplicate: CppCompileWorker) -> Dictionary:
	while true:
		_mutex.lock()
		var done: bool = duplicate._finished
		_mutex.unlock()
		if done or _cancel_requested or _cancel_all_requested:
			break
		OS.delay_msec(100)
	if _cancel_requested or _cancel_all_requested:
		return _cancelled_result()
	# The wait loop only exits on _finished or a cancel flag, so the duplicate
	# is guaranteed finished here. Read result under the mutex: run() publishes
	# result and _finished together, so this can't observe a torn state.
	_mutex.lock()
	var res: Dictionary = duplicate.result.duplicate()
	_mutex.unlock()
	if res.is_empty() or str(res.get("reason", "")) == "cancelled":
		return {}
	return res


func _error_result(output: String, reason: String) -> Dictionary:
	return {"ok": false, "output": output, "reason": reason, "exe_path": ""}


func _cancelled_result() -> Dictionary:
	return _error_result("Compilation cancelled.", "cancelled")
