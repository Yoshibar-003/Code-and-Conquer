# Reeborg's World Functionality Implementation Plan

## Overview
One of the goals of Code and Conquer is to be able to open any of the Introduction to Reeborg levels and have them all appear and function as intended.

The Fall 2026 team has developed a six-phase implementation plan to implement the required features to support this. The modular approach should allow you to make incremental progress without encountering blocking dependencies.

As of Fall 2026, Phase 1—JavaScript/Reeborg API Execution (onload/pre/post) with Stubs—has been implemented.

This document describes the six-phase plan to assist current and future developers of Code and Conquer. You're encouraged to modify the implementation plan as you see appropriate!

## The Phases

### Phase 1: JavaScript/Reeborg API Execution (onload/pre/post) with Stubs
- Reeborg's World levels use JavaScript code in three fields:
  - `onload`: Dynamic world generation (random objects, variable grid sizes, path validation)
  - `pre`: Setup before student code runs (e.g., `RUR.show_path`, `RUR.MAX_STEPS`)
  - `post`: Validation after student code runs (e.g., `RUR.check_path`, custom error messages)
- Examples:
  - Around 1 - apple uses `onload` to randomly place apples
  - Around 1 - variable uses `onload` to dynamically resize the world
  - Hurdle 1 uses `pre`/`post` for path validation
- Required Changes:
  - Implement a JavaScript interpreter (likely QuickJS or similar embedded engine)
  - Parse and execute `onload` scripts after JSON loading but before world rendering
  - Execute `pre` scripts before user code compilation
  - Execute `post` scripts after user code execution
  - Implement Reeborg's RUR API functions (`RUR.randint`, `RUR.add_object`, `RUR.set_world_size`, `RUR.check_path`, etc.)

### Phase 2: Tile/Background Type Support
- Code and Conquer renders all floor tiles identically, while Reeborg levels can use distinct tile types for visual feedback:
  - `grass` (default floor)
  - `gravel` (path tiles)
  - `pale_grass` (highlighted areas)
  - `water` (hazardous tiles - Storm levels)
- Required Changes:
  - Add tile variants to TileSet in `stuff.tres`
  - Implement tile rendering in `_build_floor()` in `map_view.gd` to read the `tiles` JSON field and set appropriate tile IDs
  - Add visual distinction for `grass` tiles, `water` tiles, etc.
    - Like in Reeborg's World, walking into a `water` tile should make you become "stuck in the mud"

### Phase 3: Path Rendering
- Reeborg levels can have visual hints (e.g., Around 1). In this case, a dashed line with arrows shows required path via `RUR.show_path()`.
- Required Changes:
  - Add path overlay system
  - Render `RUR.show_path()` as visual overlay
  - Implement grid display modes

### Phase 4: Token Support in Robot Inventory
- Reeborg levels levels can specify tokens in the robot data (e.g., Tokens 1 has `"tokens": 0` in robot data). Code and Conquer's player script in `player.gd` only tracks `carried_object` dictionary and doesn't have a dedicated token field.
- Required Changes:
  - Add `tokens` field to player state
  - Initialize from robot data if present
  - Sync with `carried_object["token"]` count

### Phase 5: Additional Object Types
- Storm and Rain levels use `leaf` objects, which are not in the supported object list in `map_view`.
- Required Changes:
  - Add leaf sprite asset
  - Add color mapping in `_get_object_color()`
  - Add to object renderer in `_build_objects()`

### Phase 6: Remaining Features
- **Robot model/sprite variants**
  - Reeborg levels can specify robot models in the `robots[0].model` field:
    - `classic` (default)
    - `light blue` (Hurdle levels)
  - Code and Conquer uses a single sprite and ignores this field in `player.gd`.
  - Required Changes:
    - Add alternate robot sprite assets
    - Modify `initialize_from_level()` to load the specified model
    - Map Reeborg model names to sprite resources
- **Goal wall condition**
  - Rain and Storm levels include `goal.walls` sub-objects (walls that must be present at goal), while Code and Conquer's win condition in `map_view.gd` only checks position and objects.
  - Required Changes:
    - Extend `check_win_condition()` to validate `goal.walls`
    - Check that specified walls exist at goal positions
- **Background image support**
  - Hurdle levels include background_image fields (e.g., `"worlds/images/stadium.png"` in Hurdle 1), while Code and Conquer has no background image loading.
  - Required Changes:
    - Add background image loading to `build_level()`
    - Render background behind the isometric grid
    - Handle missing images gracefully (fallback to solid color)
- **Decorative objects**
  - Storm 3 uses `RUR.add_decorative_object()` (grass_top_left, etc.).
  - Required Changes:
    - Implement decorative object rendering
    - Execute during `onload` script processing

  
<br>

---

# Remainder of this document discusses the implementation of Phase 1 and the current status.

As of Fall 2026, Phase 1 (JavaScript API with Stubs) has been implemented.

## What Was Implemented

### 1. JavaScript Executor Module
**File:** `execution/javascript/js_executor.gd`

A GDScript module that executes JavaScript code using Node.js (requires Node.js to be installed on the system).

**Key Features:**
- Executes JavaScript scripts (onload/pre/post) from JSON level files
- Uses Node.js via OS.execute() for JavaScript execution
- Passes level data as JSON input and receives modified data as JSON output
- Stores custom data in RUR.public object for script communication
- Returns structured results: {ok, modified_data, public_data, error}

### 2. RUR API Implementation

The following RUR API functions are implemented in JavaScript:

#### Fully Functional (Independent)
- **`RUR.randint(min, max)`** - Random number generation
- **`RUR.set_world_size(width, height)`** - Modifies cols/rows in level data
- **`RUR.give_object_to_robot(type, count)`** - Adds objects to robot's starting inventory
- **`RUR.add_object(type, x, y, options)`** - Adds objects to level at specific coordinates
- **`RUR.check_path(requiredPath, options)`** - Validates movement history against required path
- **`RUR.MAX_STEPS`** - Execution limit that can be set by scripts; this is linked to Code and Conquer's `_cmd_limit`

#### Stubbed (Data Stored, No Visual Effect)
- **`RUR.add_background_tile(type, x, y)`** - Stores tile data but doesn't render differently
- **`RUR.fill_background(type)`** - Stores default tile type but doesn't use it
- **`RUR.show_path(path, color)`** - Stores path data but doesn't render overlay
- **`RUR.state.visible_grid`** - Grid display mode (stored but not used)

### 3. Integration Points

#### Level Loading (onload)
**File:** `workstation/scripts/workstation.gd`

When a level loads:
1. `_load_level_scene()` loads the JSON file
2. If `onload` script exists, it's executed via `js_executor.execute_script()`
3. The modified level data replaces the original
4. RUR.public data is stored for later use
5. `build_level()` is called with the modified data

**Impact:** Levels can now dynamically generate worlds (random objects, variable grid sizes, etc.)

#### Pre-Execution (pre)
**File:** `workstation/scripts/workstation.gd`

When student code runs:
1. `_run_pipeline()` is called
2. If `pre` script exists, it's executed before student code compilation
3. Used for visual hints (e.g., making path semi-transparent)
4. Level data can be modified before execution

**Impact:** Visual adjustments and execution limits can be set before student code runs

#### Post-Execution (post)
**File:** `workstation/scripts/workstation.gd`

When level completes:
1. `_on_level_complete()` is triggered
2. If `post` script exists, it's executed with movement history
3. If validation fails, the level is marked as incomplete
4. Custom error messages can be displayed

**Impact:** Complex validation (path checking, custom win conditions) is now possible

### 4. Movement History Tracking

**File:** `workstation/scripts/workstation.gd`

- Added `movement_history` array to store [x, y] positions
- Every MOVE command appends the new position to history
- History is cleared on reset and level load
- Passed to post scripts for path validation

**Impact:** `RUR.check_path()` can now validate the exact movement trajectory

## Changes Made

### New Files
1. `execution/javascript/js_executor.gd` - JavaScript execution module
2. `tests/test_js_executor.gd` - Unit tests for the executor

### Modified Files
1. `execution/shared/paths.gd` - Added JS_EXECUTOR constant
2. `workstation/scripts/workstation.gd`:
   - Added js_executor instance
   - Added rur_public_data storage
   - Added movement_history tracking
   - Integrated onload execution in _load_level_scene()
   - Integrated pre execution in _run_pipeline()
   - Integrated post execution in _on_level_complete()
   - Modified _execute_cmd() to track movement
   - Modified _on_reset_button_pressed() to clear history
   - Modified _load_level_scene() to clear history

## Requirements

### System Requirements
- **Node.js** must be installed and available in PATH
- The JavaScript executor checks for Node.js availability before attempting execution
- If Node.js is not found, scripts are skipped with a warning

### Level Requirements
Levels with JavaScript scripts will work partially:
- **Fully functional:** Levels 1-4 (no scripts), 7, 13-15, 30-34 (only use supported features)
- **Partially functional:** Levels 5-6, 16-19 (scripts work but visual features are stubbed)
- **Non-functional:** Levels 23-29 (require unsupported object types like "leaf")

## Testing

### Unit Tests
Run: `godot --headless --script res://tests/test_js_executor.gd`

Tests cover:
- Empty script execution
- World size modification
- Object giving to robot
- Object addition to level
- Public data storage
- Path validation
- Path mismatch detection

### Manual Testing
1. Load a level with onload script (e.g., Around 1)
2. Verify console output shows "Executing onload script..."
3. Check that grid size and objects are modified as expected
4. Run student code and verify pre/post scripts execute
5. Reset and verify history is cleared

## Limitations

### Current Limitations
1. **No Visual Feedback:** Tile types, path overlays, and grid modes are stubbed (data stored but not rendered)
2. **Unsupported Object Types:** "leaf" and other custom objects won't work until object type support is added
3. **Node.js Dependency:** Requires Node.js to be installed; fails gracefully if missing
4. **No Background Images:** Hurdle levels with background images won't show them
5. **No Robot Models:** Robot sprite variants (light blue) not implemented

### Known Issues
- Path validation compares exact positions; Reeborg may use different coordinate systems
- Some levels use RUR functions not yet implemented (decorative objects, etc.)
- Error handling could be more granular for debugging

## Examples

### Around 1 – What Works
```javascript
// onload
RUR.set_world_size(10, 10);              // ✓ Grid is 10x10
RUR.give_object_to_robot('token', 500);  // ✓ Robot has tokens
RUR.add_background_tile('gravel', 1, 1);  // ⚠ Data stored, no visual effect
RUR.public['path'] = [[1,1], [2,1], ...]; // ✓ Path data stored
RUR.show_path(RUR.public['path'], 'black'); // ⚠ Data stored, not visible

// post
RUR.check_path(RUR.public['path'], {...}); // ✓ Validates movement
```

**Result:** Playable but harder (no visual path guidance)

### Around 1 - Apple – What Works
```javascript
for(x = 2; x <= width; x++) {
    if(RUR.randint(1, 2) == 1) {
        RUR.add_object('apple', x, 1);  // ✓ Apples randomly placed
    }
}
```

**Result:** Fully functional (randomization works, apples render)

### Storm 3 – What Doesn't Work
```javascript
RUR.add_object('leaf', x, y, {'number': nb});  // ✗ Leaf not supported
RUR.add_background_tile('water', x_pond, y_pond); // ⚠ Stored, not visible
```

**Result:** Broken (essential features missing)