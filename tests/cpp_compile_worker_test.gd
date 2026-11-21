extends SceneTree

var failures := 0


func _initialize() -> void:
	call_deferred("run_tests")


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func run_tests() -> void:
	var dir_a := "user://dedupe_test_a"
	var dir_b := "user://dedupe_test_b"

	var winner = CppCompileWorker.new()
	winner._build_dir = dir_a
	winner._register()
	var other_dir = CppCompileWorker.new()
	other_dir._build_dir = dir_b
	other_dir._register()
	var already_done = CppCompileWorker.new()
	already_done._build_dir = dir_a
	already_done._finished = true
	already_done._register()

	var waiter = CppCompileWorker.new()
	waiter._build_dir = dir_a
	var found := waiter._find_duplicate()
	check(found == winner, "Should find the unfinished worker with the same build dir")
	check(waiter._find_duplicate() != other_dir, "Should not match a worker with a different build dir")
	check(waiter._find_duplicate() != already_done, "Should not match a finished worker")

	# A completed real result is adopted.
	winner._finished = true
	winner.result = {"ok": true, "output": "", "reason": "", "exe_path": "prog.exe"}
	var adopter = CppCompileWorker.new()
	check(adopter._reuse_duplicate(winner), "Should adopt a completed real result")
	check(bool(adopter.result.get("ok", false)), "Adopted result should carry the original ok flag")
	check(str(adopter.result.get("exe_path", "")) == "prog.exe", "Adopted result should carry exe_path")

	# A cancelled result is transient and must not be adopted.
	var cancelled = CppCompileWorker.new()
	cancelled._build_dir = dir_a
	cancelled._finished = true
	cancelled.result = {"ok": false, "output": "Compilation cancelled.", "reason": "cancelled", "exe_path": ""}
	var reject_cancel = CppCompileWorker.new()
	check(not reject_cancel._reuse_duplicate(cancelled), "Cancelled result must not be adopted")
	check(reject_cancel.result.is_empty(), "Rejected result must leave worker result empty")

	# An empty result (aborted compile) must not be adopted either.
	var empty = CppCompileWorker.new()
	empty._build_dir = dir_a
	empty._finished = true
	var reject_empty = CppCompileWorker.new()
	check(not reject_empty._reuse_duplicate(empty), "Empty result must not be adopted")

	# A cancelled waiter reports handled instead of adopting anything.
	var blocked = CppCompileWorker.new()
	blocked._build_dir = dir_a
	blocked._cancel_requested = true
	var pending = CppCompileWorker.new()
	pending._build_dir = dir_a
	check(blocked._reuse_duplicate(pending), "Cancelled waiter should return handled")
	check(str(blocked.result.get("reason", "")) == "cancelled", "Cancelled waiter should produce a cancelled result")

	winner._unregister()
	other_dir._unregister()
	already_done._unregister()

	print("CPP COMPILE WORKER TESTS: %d failures" % failures)
	quit(0 if failures == 0 else 1)
