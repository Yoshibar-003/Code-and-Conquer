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
	waiter._register()
	var found := waiter._find_duplicate()
	check(found == winner, "Should find the earlier-registered worker with the same build dir")
	check(waiter._find_duplicate() != other_dir, "Should not match a worker with a different build dir")
	check(waiter._find_duplicate() != already_done, "Should not match a finished worker")

	# The earlier registrant must not dedupe onto the later one, so two
	# workers can never wait on each other.
	check(winner._find_duplicate() == null, "Earlier registrant should not dedupe onto a later worker")
	waiter._unregister()

	# A completed real result is adopted.
	winner._finished = true
	winner.result = {"ok": true, "output": "", "reason": "", "exe_path": "prog.exe"}
	var adopter = CppCompileWorker.new()
	var adopted: Dictionary = adopter._reuse_duplicate(winner)
	check(not adopted.is_empty(), "Should adopt a completed real result")
	check(bool(adopted.get("ok", false)), "Adopted result should carry the original ok flag")
	check(str(adopted.get("exe_path", "")) == "prog.exe", "Adopted result should carry exe_path")

	# A cancelled result is transient and must not be adopted.
	var cancelled = CppCompileWorker.new()
	cancelled._build_dir = dir_a
	cancelled._finished = true
	cancelled.result = {"ok": false, "output": "Compilation cancelled.", "reason": "cancelled", "exe_path": ""}
	var reject_cancel = CppCompileWorker.new()
	check(reject_cancel._reuse_duplicate(cancelled).is_empty(), "Cancelled result must not be adopted")

	# An empty result (aborted compile) must not be adopted either.
	var empty = CppCompileWorker.new()
	empty._build_dir = dir_a
	empty._finished = true
	var reject_empty = CppCompileWorker.new()
	check(reject_empty._reuse_duplicate(empty).is_empty(), "Empty result must not be adopted")

	# A cancelled waiter reports handled instead of adopting anything.
	var blocked = CppCompileWorker.new()
	blocked._build_dir = dir_a
	blocked._cancel_requested = true
	var pending = CppCompileWorker.new()
	pending._build_dir = dir_a
	var blocked_result: Dictionary = blocked._reuse_duplicate(pending)
	check(str(blocked_result.get("reason", "")) == "cancelled", "Cancelled waiter should produce a cancelled result")

	winner._unregister()
	already_done._unregister()
	# other_dir stays registered: unfinished, earlier seq, different dir —
	# it would match any probe if the build-dir filter were broken.
	var dir_probe = CppCompileWorker.new()
	dir_probe._build_dir = "user://dedupe_test_c"
	dir_probe._register()
	check(dir_probe._find_duplicate() == null, "Different build dir must not dedupe")
	dir_probe._unregister()

	# A same-dir probe must not match a finished worker.
	var fin = CppCompileWorker.new()
	fin._build_dir = "user://dedupe_test_c"
	fin._finished = true
	fin._register()
	var fin_probe = CppCompileWorker.new()
	fin_probe._build_dir = "user://dedupe_test_c"
	fin_probe._register()
	check(fin_probe._find_duplicate() == null, "Finished worker must not dedupe")
	fin_probe._unregister()
	fin._unregister()
	other_dir._unregister()

	print("CPP COMPILE WORKER TESTS: %d failures" % failures)
	quit(0 if failures == 0 else 1)
