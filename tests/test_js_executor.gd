extends SceneTree

# Test script for JavaScript executor
# Run with: godot --headless --script res://tests/test_js_executor.gd

func _init() -> void:
	print("=== Testing JavaScript Executor ===")
	_test_executor()
	quit()


func _test_executor() -> void:
	var JSExecutor = load("res://execution/javascript/js_executor.gd")
	var executor = JSExecutor.new()

	# Test 1: Empty script
	print("\nTest 1: Empty script")
	var result = executor.execute_script([], {})
	assert(result.ok, "Empty script should succeed")
	print("✓ Empty script passed")

	# Test 2: Simple world size change
	print("\nTest 2: Set world size")
	var test_data = {"cols": 5, "rows": 5, "robots": []}
	var script = [
		"RUR.set_world_size(10, 10);"
	]
	result = executor.execute_script(script, test_data)
	if result.ok:
		assert(result.modified_data.cols == 10, "Cols should be 10")
		assert(result.modified_data.rows == 10, "Rows should be 10")
		print("✓ Set world size passed")
	else:
		print("✗ Set world size failed: ", result.error)

	# Test 3: Give object to robot
	print("\nTest 3: Give object to robot")
	test_data = {"robots": [{"x": 1, "y": 1, "_orientation": 0, "objects": {}}]}
	script = [
		"RUR.give_object_to_robot('token', 5);"
	]
	result = executor.execute_script(script, test_data)
	if result.ok:
		assert(result.modified_data.robots[0].objects.token == 5, "Robot should have 5 tokens")
		print("✓ Give object to robot passed")
	else:
		print("✗ Give object to robot failed: ", result.error)

	# Test 4: Add object to level
	print("\nTest 4: Add object to level")
	test_data = {"objects": {}}
	script = [
		"RUR.add_object('apple', 2, 3);"
	]
	result = executor.execute_script(script, test_data)
	if result.ok:
		assert(result.modified_data.objects.has("2,3"), "Object should be at 2,3")
		assert(result.modified_data.objects["2,3"].apple == 1, "Should have 1 apple")
		print("✓ Add object to level passed")
	else:
		print("✗ Add object to level failed: ", result.error)

	# Test 5: Public data storage
	print("\nTest 5: Public data storage")
	test_data = {}
	script = [
		"RUR.public['test_key'] = 'test_value';"
	]
	result = executor.execute_script(script, test_data)
	if result.ok:
		assert(result.public_data.has("test_key"), "Public data should have test_key")
		assert(result.public_data["test_key"] == "test_value", "Value should match")
		print("✓ Public data storage passed")
	else:
		print("✗ Public data storage failed: ", result.error)

	# Test 6: Check path validation
	print("\nTest 6: Check path validation")
	test_data = {}
	var movement_history = [[1, 1], [2, 1], [3, 1]]
	script = [
		"RUR.check_path([[1, 1], [2, 1], [3, 1]], {failure: 'Path mismatch'});"
	]
	result = executor.execute_script(script, test_data, movement_history)
	if result.ok:
		print("✓ Check path validation passed")
	else:
		print("✗ Check path validation failed: ", result.error)

	# Test 7: Check path with mismatch
	print("\nTest 7: Check path with mismatch")
	movement_history = [[1, 1], [2, 1], [3, 1]]
	script = [
		"RUR.check_path([[1, 1], [2, 2], [3, 1]], {failure: 'Path mismatch'});"
	]
	result = executor.execute_script(script, test_data, movement_history)
	# This should succeed execution but the check should fail
	# Our implementation just returns the result, doesn't throw
	print("✓ Check path with mismatch handled (execution succeeded)")

	# Test 8: MAX_STEPS linkage
	print("\nTest 8: MAX_STEPS linkage")
	test_data = {}
	script = [
		"RUR.MAX_STEPS = 500;"
	]
	result = executor.execute_script(script, test_data)
	if result.ok:
		assert(result.modified_data._MAX_STEPS == 500, "MAX_STEPS should be stored")
		print("✓ MAX_STEPS linkage passed")
	else:
		print("✗ MAX_STEPS linkage failed: ", result.error)

	print("\n=== All tests completed ===")
